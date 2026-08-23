#!/bin/sh
#
# tank-snapshot.sh — scheduled ZFS snapshots of `tank`, with tiered retention.
#
# WHAT THIS PROTECTS AGAINST, AND WHAT IT DOESN'T
# The mirror protects against a drive dying. It does nothing about the far more
# likely event: you deleting the wrong folder, an application rewriting files it
# shouldn't, or ransomware. A mirror replicates a deletion to both members
# instantly and faithfully. Snapshots are the only thing in this setup that can
# undo that. They are NOT a backup — they live inside `tank`, on the same two
# drives, behind the same JMicron bridge; a snapshot on a dead pool dies with the
# pool. That is what the third drive (todo 3) is for.
#
# THE THING PEOPLE GET WRONG ABOUT COST
# A snapshot is not a copy. ZFS is copy-on-write, so creating one copies nothing
# — it pins the blocks that exist at that instant and says "don't free these".
# Unchanged data is shared, stored exactly once, however many snapshots
# reference it. A snapshot only starts costing space as the live filesystem
# DIVERGES from it. So the bill is driven by churn, not by capacity:
# tank/media (written once, read forever) costs approximately nothing forever,
# while tank/documents costs whatever you rewrote. Watch `usedbysnapshots`.
#
# The corollary that shapes this script: an unchanged dataset snapshotted every
# week for a year produces 52 identical snapshots holding zero extra bytes — a
# few KB of metadata each. Harmless, but it also means a "keep the last 3"
# window covers three weeks of NOTHING. See "SKIP IF UNCHANGED" below.
#
# --- DESIGN: THREE DECISIONS, EACH LOAD-BEARING ---------------------------
#
# 1. DUE-NESS IS DERIVED FROM SNAPSHOT AGE, NOT FROM THE CALENDAR.
#
# The obvious design is three plists — daily, weekly on Sunday, monthly on the
# 1st. It has a hole this machine will fall into. launchd runs a missed
# StartCalendarInterval job ONCE at the next wake, so if the Mac is asleep every
# Sunday at 02:00, a script that checks "is today Sunday?" skips the weekly tier
# for as long as that pattern holds, silently. Instead: one job, daily, and a
# tier is due when the newest snapshot IN THAT TIER is older than the tier's
# interval. Robust to sleep, missed runs, clock changes, and hand-kickstarts.
# It also makes the whole script idempotent — run it twice in a row and the
# second run correctly does nothing.
#
# SLACK_SECS exists because of an off-by-a-jitter bug that would have halved the
# snapshot rate. If the daily tier fires at 02:00:00 and the next run lands at
# 01:59:58, the age is 86398 < 86400, "not due", and a whole day is skipped.
# Allowing a tier to be due half a run-period early absorbs that without ever
# letting a tier fire twice in one run (nothing here runs more than once a day).
#
# 2. SKIP IF NOTHING CHANGED — PER TIER, NOT PER DATASET.
#
# `zfs get written@<snap> <dataset>` is the space written to the dataset since
# that specific snapshot. Zero means the dataset is byte-for-byte what that
# snapshot already holds, so a new snapshot would be a duplicate name over
# identical data. We skip it.
#
# This converts "keep 8 weekly" from "8 weeks of history" into "the last 8
# STATES this dataset was ever in". For tank/my_media — photos and video edited
# maybe twice a year — that is the difference between eight weeks of coverage
# and effectively years of it, at identical (near-zero) cost. It is the single
# highest-value line in this script.
#
# IT MUST BE PER-TIER, and this is the subtle part. Using the dataset's plain
# `written` property compares against the newest snapshot of ANY tier. So on a
# dataset with a daily tier, `written` is almost always 0 right after the daily
# fires — and the weekly tier, comparing against that, would conclude "nothing
# changed" and never advance again. The weekly tier has to compare against the
# last WEEKLY. Hence written@<that tier's newest>, per tier.
#
# Fails OPEN: if the property is unreadable for any reason we take the snapshot.
# A spurious snapshot costs a few KB. A skipped one can cost data.
#
# Note that a delete-only week still registers written > 0 — removing a file
# rewrites directory metadata, which is newly written space — so the guard does
# not skip precisely the snapshot you would most want. Asserted directly in
# tests/snapshot-retention/, because if it were ever false this guard would have
# to go.
#
# ONE PROPERTY OF `written` THAT DOES NOT MATTER HERE BUT WILL CONFUSE YOU
# LATER: it is ON-DISK accounting, so it does not move until the writes land in
# a synced transaction group — up to zfs_txg_timeout (5s) behind the write, and
# POSIX sync(8) does NOT force that; `zpool sync` does. Measured 2026-08-23:
# writing 256 KB and calling sync(8) left `written` completely unchanged.
# Irrelevant at a daily cadence, since every write this decides about is hours
# old. The only reachable consequence is that a write in the last few seconds
# before 02:00 gets attributed to tomorrow's snapshot instead of today's, which
# is not worth a line of code. It DOES matter enormously to the test harness,
# and it is what made the first run of that suite report 11 failures.
#
# 3. THE PRUNER IS SCOPED TO ITS OWN PREFIX AND WILL NOT FIGHT A HOLD.
#
# Every snapshot this script creates is named <prefix>-<tier>-<timestamp>, and
# the pruner only ever considers names matching that shape. It cannot destroy a
# snapshot a human took by hand, and — this is the one that matters — it cannot
# destroy todo 3's incremental send base.
#
# That interaction is worth stating plainly because it is silent and expensive:
# `zfs send -i A B` requires snapshot A to still exist on BOTH sides. If this
# pruner destroys the base that the offsite drive last received, the next sync
# cannot do an incremental and degrades to a full send of the entire pool over
# USB. So the backup job must `zfs hold` its base. `zfs destroy` on a held
# snapshot fails, which is the correct outcome, so this script logs it as an
# expected skip rather than an error, and never passes -d (defer) or any force
# flag. A deferred destroy would fire the moment the hold was released, which is
# exactly the surprise we are avoiding.
#
# That refusal is recognised by asking `zfs holds`, not by matching the error
# text. Matching the text is what the first version did and it was wrong on this
# very build — see the comment in prune(). The consequence of getting it wrong is
# not subtle: it turns a correctly-held send base into a nightly failure alert.
#
# --- EXIT CODES — the summary, readable via -------------------------------
#   launchctl print system/local.tank-snapshot | grep 'last exit'
#   0  ran to completion (snapshots taken and/or nothing was due)
#   1  refused to run (pool not imported, or not ONLINE/DEGRADED)
#   2  a snapshot or a prune failed — READ THE LOG
#   3  a configured dataset does not exist
#
# --- NOTIFICATIONS: FAILURES ALWAYS, PLUS A MONTHLY HEARTBEAT -------------
#
# The scrub daemon posts every run on purpose, because at twelve runs a year the
# message IS the heartbeat and its absence on the 1st is the signal. That
# reasoning does not transfer to a job that runs 365 times a year — a daily
# Discord message is noise, and noise is how a real alert gets missed.
#
# So: alert on every failure, and additionally post one summary whenever the
# last summary went out more than HEARTBEAT_SECS ago. Same ~12/year heartbeat
# rate as the scrub, same reading: nothing arriving for a month means the daemon
# stopped running, which is otherwise indistinguishable from "all quiet".
#
# Deliberately NOT tied to the monthly tier firing. With skip-if-unchanged a
# dataset that never changes never takes a monthly snapshot, so a heartbeat
# hung off that would go quiet exactly when everything is fine — inverting the
# signal. It is hung off its own timestamp file instead.
#
# --- TESTING — kickstart, never a terminal --------------------------------
#   sudo launchctl bootstrap system /Library/LaunchDaemons/local.tank-snapshot-test.plist
#   sudo launchctl kickstart -k system/local.tank-snapshot-test
#   tail -f /var/log/tank-snapshot.log
#   sudo launchctl bootout system/local.tank-snapshot-test   # do not skip this
#   sudo rm /Library/LaunchDaemons/local.tank-snapshot-test.plist
#
# A terminal run proves less than it looks like: sudo inherits the terminal
# app's Full Disk Access grant, which is exactly how the boot-unlock bug hid for
# three cold boots. This daemon should not need FDA — `zfs snapshot` acts on an
# already-imported pool through the /dev/zfs ioctl, so the kernel does the disk
# I/O and no raw device is opened — but that was also "just a prediction" for
# the scrub daemon until it was measured. Verify once:
#   /usr/bin/log show --last 5m --style compact | grep 'deny(1)'
# and expect zero hits for zfs.
#
# AND DO NOT STOP AT A GREEN EXIT CODE. The scrub daemon's kickstart returned 0
# with a real bug live in a branch the test could not reach. Ask what the run
# did NOT execute. Here that is specifically the PRUNE path: on a virgin pool
# the first run creates one snapshot per tier and every tier is under its keep
# count, so nothing is pruned and the entire retention half of this script is
# unexercised. tests/snapshot-prune/ drives it deliberately.
#
# Rollback: sudo launchctl bootout system/local.tank-snapshot
#           sudo rm /Library/LaunchDaemons/local.tank-snapshot.plist
#           sudo rm /usr/local/sbin/tank-snapshot.sh
# Existing snapshots survive all of that and keep costing whatever they cost.
# To also drop them:
#   zfs list -H -t snapshot -o name -r tank | grep '@auto-' | xargs -n1 sudo zfs destroy
# Read that list before running it.
#
# NO LOCK, ON PURPOSE. A run is seconds of ioctls, launchd will not start a
# second instance of the same label while one is live, and the two ways a race
# could still happen are both benign: a duplicate `zfs snapshot` fails with
# "dataset already exists" and a double destroy fails with "does not exist",
# both caught and logged. A lockfile would add a stale-lock failure mode worse
# than the problem it solves.

set -u

ZFS=/usr/local/zfs/bin/zfs
ZPOOL=/usr/local/zfs/bin/zpool
POOL=tank

# Overridable for one reason: combined with DRY_RUN=1 it lets the entire
# decision path — tier due-ness, skip-if-unchanged, prune arithmetic — be
# smoke-tested by an unprivileged user against the real pool, since `zfs list`
# and `zfs get` need no root and nothing gets created. That is a check on the
# logic, NOT a substitute for the kickstart test: it runs with a terminal's
# environment and a terminal's TCC grant, which is the exact mistake that hid
# the boot-unlock bug for three cold boots. Nothing in production sets these.
LOG=${TANK_SNAPSHOT_LOG:-/var/log/tank-snapshot.log}
STATE=${TANK_SNAPSHOT_STATE:-/var/log/tank-snapshot.last}
HEARTBEAT=${TANK_SNAPSHOT_HEARTBEAT:-/var/log/tank-snapshot.heartbeat}

# Snapshot name prefix. Overridable ONLY so the test harness can create
# snapshots that are provably distinguishable from production ones: a cleanup
# scoped to `test-*` cannot delete an `auto-*` snapshot no matter how wrong it
# is. Nothing in production sets this.
PREFIX=${TANK_SNAPSHOT_PREFIX:-auto}

# Tier intervals. "Monthly" is a flat 30 days rather than a calendar month, so
# it drifts against the calendar — which is fine and is the point: nothing here
# cares what day of the month it is, only how stale the newest monthly is.
#
# Overridable for the test harness, which sets all three to 1 so every kickstart
# finds every tier due. Set them via EnvironmentVariables in the test plist, NOT
# via `sudo launchctl setenv`, which fails with "150: Operation not permitted
# while System Integrity Protection is engaged" because it mutates launchd's
# global environment. Measured 2026-08-22 on the scrub daemon.
DAILY_SECS=${TANK_SNAPSHOT_DAILY_SECS:-86400}
WEEKLY_SECS=${TANK_SNAPSHOT_WEEKLY_SECS:-604800}
MONTHLY_SECS=${TANK_SNAPSHOT_MONTHLY_SECS:-2592000}

# Half the daily run period. See decision 1 in the header: this is what stops a
# couple of seconds of scheduling jitter from skipping a whole day, and it is
# small enough that no tier can ever fire twice in one day.
SLACK_SECS=${TANK_SNAPSHOT_SLACK_SECS:-43200}

# 30 days. See the NOTIFICATIONS section.
HEARTBEAT_SECS=${TANK_SNAPSHOT_HEARTBEAT_SECS:-2592000}

# 1 = decide and log everything, create and destroy nothing. The first thing to
# run after any edit to the config table at the bottom, because it shows exactly
# what a real run would do.
DRY_RUN=${TANK_SNAPSHOT_DRY_RUN:-0}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

ZEDRC=${TANK_SNAPSHOT_ZEDRC:-/etc/zfs/zed.d/zed.rc}
NOTIFY_MAX_CHARS=1500

# Push a message to whatever channel zed is configured for, reusing zed's own
# webhook URL so delivery is configured in exactly one place.
#
# This is deliberately a copy of tank-scrub.sh's notify() rather than a shared
# sourced library. Two daemons, two independent failure domains: a syntax error
# in a common file would take out the boot unlock's sibling too, and the whole
# staged-review pattern (edit in ~/repos/nas, sh -n, diff -u, install) works on
# self-contained files. If a third daemon shows up, revisit.
#
# WHY NOT zed_notify(), which is sourceable and would be less code: zed's Slack
# backend cannot detect its own failure against Discord. Measured 2026-08-23 —
# a POST to a webhook with a bad token returns
#   HTTP 401  {"message": "Invalid Webhook Token", "code": 50027}
# curl exits 0 because zed does not pass -f, and zed's error check greps for
# Slack's nested {"error": ... "message": ...} shape, which does not match
# Discord's flat {"message": ...}. So zed logs a rejected post as delivered. For
# the one channel that reports the daemon's own failures that is exactly
# backwards, so this checks the HTTP status itself.
#
# The URL is READ, not sourced — no executing a config file from inside the
# daemon. It must end in /slack: that is Discord's Slack-compatible endpoint,
# and omitting the suffix fails SILENTLY (HTTP 400, reported as delivered).
#
# $1 = subject, $2 = body.
notify() {
	nurl=$(awk -F'"' '/^ZED_SLACK_WEBHOOK_URL=/ { print $2; exit }' "$ZEDRC" 2>/dev/null)
	if [ -z "$nurl" ]; then
		log "  notify: no channel set (ZED_SLACK_WEBHOOK_URL in $ZEDRC) — log only"
		return 0
	fi

	# Same escaping and truncation as tank-scrub.sh. Discord rejects a body over
	# 2000 characters with a 400. `head -c` counts bytes so it can cut a
	# multi-byte character in half; iconv -c drops the incomplete sequence rather
	# than relying on Discord's leniency. iconv's stderr is discarded because it
	# warns about the very truncation we asked for.
	nbody=$(printf '%s' "$2" | head -c "$NOTIFY_MAX_CHARS" |
		iconv -c -f UTF-8 -t UTF-8 2>/dev/null | awk '
		{ ORS = "\\n" }
		{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t");
		  gsub(/\f/, "\\f"); gsub(/\r/, "\\r"); print }')
	npayload=$(printf '{"text": "*%s*\\n```%s```"}' "$1" "$nbody")

	nstatus=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
		-X POST "$nurl" \
		--header 'Content-Type: application/json' \
		--data-binary "$npayload" 2>/dev/null)
	nrc=$?

	case "$nstatus" in
	2*) log "  notify: delivered (HTTP $nstatus)" ;;
	*)
		log "  notify: DELIVERY FAILED (curl rc=$nrc, HTTP ${nstatus:-none})."
		log "          The message above exists ONLY in this log. Check the webhook"
		log "          URL in $ZEDRC, and that this machine has network at 02:00."
		;;
	esac
}

# Loud channel for things a human must see: the log, the unified log (greppable
# next to the kernel's own ZFS messages), and the notification channel.
#
# $1 = one-line summary. $2 = optional detail for the notification body.
alert() {
	log "$1"
	/usr/bin/logger -t tank-snapshot -p daemon.err "$1"
	if [ "${2:-}" != "" ]; then
		notify "tank-snapshot: $POOL on $(hostname -s)" "$1

$2"
	else
		notify "tank-snapshot: $POOL on $(hostname -s)" "$1"
	fi
}

# ---------------------------------------------------------------------------
# Tier helpers
# ---------------------------------------------------------------------------

tier_interval() {
	case "$1" in
	daily) echo "$DAILY_SECS" ;;
	weekly) echo "$WEEKLY_SECS" ;;
	monthly) echo "$MONTHLY_SECS" ;;
	*) echo 0 ;;
	esac
}

# Snapshots of $1 belonging to tier $2, OLDEST FIRST, short names only.
#
# -d 1 keeps this to the dataset's own snapshots rather than its children's,
# which matters because the config table treats every dataset independently.
# Sorted by the `creation` property rather than by name: the timestamp in the
# name sorts chronologically today, but creation order is the actual truth and
# survives a clock change or a DST shift.
#
# The grep anchors on <prefix>-<tier>- followed by a digit, so this can never
# return a hand-made snapshot, a `zfs send` base, or another tier's snapshot
# (`daily` is not a prefix of `weekly` or `monthly`, but pinning the shape is
# cheap insurance against a future tier name that is).
tier_snapshots() {
	"$ZFS" list -H -t snapshot -d 1 -o name -s creation "$1" 2>/dev/null |
		sed -n "s|^$1@||p" | grep "^$PREFIX-$2-[0-9]"
}

# Age in seconds of snapshot $1@$2, or empty if it cannot be read.
snap_age() {
	_created=$("$ZFS" get -Hp -o value creation "$1@$2" 2>/dev/null)
	case "$_created" in
	'' | *[!0-9]*) return 0 ;;
	esac
	echo $((NOW - _created))
}

# Space written to dataset $1 since snapshot $2. Empty if unreadable.
written_since() {
	"$ZFS" get -Hp -o value "written@$2" "$1" 2>/dev/null
}

take() {
	_ds=$1
	_snap="$PREFIX-$2-$STAMP"
	if [ "$DRY_RUN" = 1 ]; then
		log "    DRY RUN: would create $_ds@$_snap"
		n_taken=$((n_taken + 1))
		return 0
	fi
	# One snapshot per call rather than batching several names into one atomic
	# `zfs snapshot a b c`. Atomicity across tiers buys nothing — snapshots taken
	# in the same run of the same dataset are identical in content either way —
	# and per-call error handling is worth more than that.
	#
	# There is deliberately NO cross-dataset atomicity either. tank/documents and
	# tank/my_media are independent; nothing here spans them transactionally (no
	# database, no application state), so a crash-consistent point in time across
	# all four datasets is not a property worth buying.
	_out=$("$ZFS" snapshot "$_ds@$_snap" 2>&1)
	_rc=$?
	if [ "$_rc" -ne 0 ]; then
		log "    FAILED to create $_ds@$_snap: ${_out:-<no output>}"
		n_failed=$((n_failed + 1))
		FAILURES="${FAILURES}snapshot $_ds@$_snap: ${_out:-<no output>}
"
		return 1
	fi
	log "    created $_ds@$_snap"
	n_taken=$((n_taken + 1))
	SUMMARY="${SUMMARY}  + $_ds@$_snap
"
	return 0
}

# Destroy the oldest snapshots in tier $2 of dataset $1 until only $3 remain.
prune() {
	_ds=$1
	_tier=$2
	_keep=$3

	# A tier with keep 0 is switched off in the config table, so it never took
	# anything and there is nothing of its to prune. Returning early rather than
	# destroying everything matters if a tier is ever turned off after running:
	# its existing snapshots are then left alone for a human to decide about,
	# instead of being silently reaped by an unrelated config edit.
	if [ "$_keep" -lt 1 ]; then
		return 0
	fi

	_all=$(tier_snapshots "$_ds" "$_tier")
	_n=$(printf '%s' "$_all" | grep -c . 2>/dev/null)
	[ -z "$_n" ] && _n=0
	if [ "$_n" -le "$_keep" ]; then
		return 0
	fi

	_excess=$((_n - _keep))
	# Oldest first, so `head` is the doomed set. Snapshot names cannot contain
	# whitespace in ZFS, so the unquoted word split below is safe.
	_doomed=$(printf '%s\n' "$_all" | head -n "$_excess")
	log "    tier $_tier: $_n snapshots, keeping $_keep, destroying $_excess oldest"

	for _s in $_doomed; do
		if [ "$DRY_RUN" = 1 ]; then
			log "    DRY RUN: would destroy $_ds@$_s"
			n_pruned=$((n_pruned + 1))
			continue
		fi
		# No -d, no -f, no -r. See decision 3 in the header: a held snapshot is
		# something else's incremental send base and EBUSY here is the system
		# working. -d would defer the destroy until the hold was released, which
		# turns a clean refusal into a delayed ambush.
		_out=$("$ZFS" destroy "$_ds@$_s" 2>&1)
		_rc=$?
		if [ "$_rc" -eq 0 ]; then
			log "    destroyed $_ds@$_s"
			n_pruned=$((n_pruned + 1))
			continue
		fi
		# CLASSIFY THE REFUSAL STRUCTURALLY, NOT BY PARSING THE MESSAGE.
		# `zfs holds` answers the actual question — is something pinning this
		# snapshot — and is immune to wording, which is NOT stable across
		# implementations. This build says
		#     cannot destroy snapshot <snap>: it's being held. Run 'zfs holds -r
		#     <snap>' to see holders.
		# while upstream OpenZFS says
		#     cannot destroy '<snap>': snapshot is busy
		# The first version of this matched *busy*, missed the real message, and
		# therefore counted a hold doing its job as a failure and exited 2 — i.e.
		# it would have alerted every single night once todo 3 started holding its
		# send base. Caught by tests/snapshot-retention/ on 2026-08-23, and the
		# reason that suite asserts on the exit code and not just the outcome.
		if [ -n "$("$ZFS" holds -H "$_ds@$_s" 2>/dev/null)" ]; then
			# Expected and correct when the backup job holds its send base. Logged
			# rather than alerted, but counted: if a hold is ever forgotten, the
			# tier grows without bound and this is the only line that will say so.
			log "    HELD, not destroyed: $_ds@$_s"
			log "          Expected if the backup job holds this as a send base."
			log "          Holders: $("$ZFS" holds -H "$_ds@$_s" 2>/dev/null | tr '\n' ' ')"
			n_held=$((n_held + 1))
			continue
		fi

		case "$_out" in
		*"dependent clones"*)
			# Also a correct refusal rather than a fault: -R would destroy the
			# clone with it, which is never what a retention pruner should do.
			# Nothing in this setup creates clones, so this line appearing at all
			# is worth a human look even though it is not an error.
			log "    HELD by a clone, not destroyed: $_ds@$_s ($_out)"
			log "          Nothing here creates clones — worth understanding why."
			n_held=$((n_held + 1))
			;;
		*)
			log "    FAILED to destroy $_ds@$_s: ${_out:-<no output>}"
			n_failed=$((n_failed + 1))
			FAILURES="${FAILURES}destroy $_ds@$_s: ${_out:-<no output>}
"
			;;
		esac
	done
}

# ---------------------------------------------------------------------------
# One dataset: decide each tier, take what is due and changed, then prune.
#
# $1 = dataset, $2 = keep daily, $3 = keep weekly, $4 = keep monthly (0 = off)
# ---------------------------------------------------------------------------
process_dataset() {
	_ds=$1
	set -- daily "$2" weekly "$3" monthly "$4"

	if ! "$ZFS" list -H -o name "$_ds" >/dev/null 2>&1; then
		# A dataset in the config table that does not exist is a configuration
		# error, not a transient condition, and it fails in the direction that
		# matters: the data it was meant to protect is unprotected while the run
		# still exits looking healthy. Say so out loud.
		alert "MISSING: configured dataset $_ds does not exist — nothing snapshotted for it."
		log "      Either create it, or remove it from the config table at the"
		log "      bottom of /usr/local/sbin/tank-snapshot.sh."
		n_missing=$((n_missing + 1))
		return 0
	fi

	log "$_ds:"

	while [ $# -ge 2 ]; do
		_tier=$1
		_keep=$2
		shift 2

		if [ "$_keep" -lt 1 ]; then
			continue
		fi

		_interval=$(tier_interval "$_tier")
		_newest=$(tier_snapshots "$_ds" "$_tier" | tail -n 1)

		if [ -z "$_newest" ]; then
			# Bootstrap: no snapshot in this tier yet, so it is due by definition
			# and there is no reference point to compare `written` against. Take it
			# unconditionally — this is the run that establishes the baseline.
			log "  $_tier: no snapshot yet — taking baseline"
			take "$_ds" "$_tier"
			prune "$_ds" "$_tier" "$_keep"
			continue
		fi

		_age=$(snap_age "$_ds" "$_newest")
		if [ -z "$_age" ]; then
			# Unreadable creation time. Fail open, same reasoning as `written`.
			log "  $_tier: could not read age of $_newest — taking one anyway"
			take "$_ds" "$_tier"
			prune "$_ds" "$_tier" "$_keep"
			continue
		fi

		if [ "$_age" -lt $((_interval - SLACK_SECS)) ]; then
			log "  $_tier: not due (newest is ${_age}s old, interval ${_interval}s)"
			continue
		fi

		_written=$(written_since "$_ds" "$_newest")
		case "$_written" in
		0)
			# Byte-for-byte identical to the snapshot this tier already holds. A
			# new one would be a second name over the same blocks. Skipping is what
			# turns "keep N" into "the last N states" instead of "the last N
			# weeks" — see decision 2 in the header.
			log "  $_tier: due, but nothing written since $_newest — skipping"
			n_skipped=$((n_skipped + 1))
			continue
			;;
		'' | *[!0-9]*)
			log "  $_tier: due; written@$_newest unreadable — taking one anyway"
			;;
		*)
			log "  $_tier: due (${_age}s old, ${_written} bytes written since $_newest)"
			;;
		esac

		take "$_ds" "$_tier"
		prune "$_ds" "$_tier" "$_keep"
	done
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

NOW=$(date +%s)
STAMP=$(date '+%Y-%m-%d-%H%M%S')

n_taken=0
n_pruned=0
n_failed=0
n_missing=0
n_held=0
n_skipped=0
SUMMARY=
FAILURES=

if [ "$DRY_RUN" = 1 ]; then
	log "--- start (pid $$) DRY RUN — deciding only, creating and destroying nothing ---"
else
	log "--- start (pid $$) ---"
fi

# ---------------------------------------------------------------------------
# Preflight. Same principle as the scrub daemon: a scheduled job must not wedge
# or make things worse. Missing a day of snapshots is recoverable; a hung daemon
# holding the pool is less so.
# ---------------------------------------------------------------------------

if ! "$ZPOOL" list -H -o name "$POOL" >/dev/null 2>&1; then
	alert "REFUSED: pool $POOL is not imported. Nothing to snapshot."
	log "      This is itself the problem — tank should always be imported."
	log "      Check /var/log/tank-boot-unlock.log first; that daemon owns import."
	exit 1
fi

health=$("$ZPOOL" list -H -o health "$POOL" 2>/dev/null)
case "$health" in
ONLINE)
	log "health: ONLINE"
	;;
DEGRADED)
	# Snapshot anyway, and deliberately. A snapshot is a metadata operation on a
	# pool that is still serving reads and writes, and if a member is genuinely
	# failing then pinning the current state is worth MORE than usual, not less.
	# Say so loudly though: on this hardware DEGRADED is remarkable in itself.
	# The 2026-08-17 pull test showed a removed drive does not produce DEGRADED at
	# all — the JMicron bridge drops both LUNs and the pool suspends instead. So
	# DEGRADED here means a genuine per-device fault the bridge survived, a
	# failure mode never yet observed on this setup.
	alert "health: DEGRADED — snapshotting anyway, but investigate. See zpool status -v."
	;;
*)
	# SUSPENDED / UNAVAIL / empty. failmode is deliberately `wait`, so anything
	# that touches a suspended pool hangs rather than erroring, and `zfs snapshot`
	# would block in an uninterruptible ioctl that SIGKILL does not free. Refuse
	# instead. Reading state is safe even here — measured during the pull test,
	# `zpool status` kept answering with a drive physically removed.
	alert "REFUSED: pool health is '${health:-<unreadable>}', not ONLINE or DEGRADED."
	log "      Not issuing snapshots: failmode=wait means zfs snapshot would block"
	log "      forever in the ioctl, and SIGKILL does not free an uninterruptible"
	log "      sleep. A suspended pool is a bridge fault. Recovery is one command"
	log "      once the devices are back: sudo zpool clear $POOL"
	log "      See the drive-pull test writeup in ~/repos/nas/tests/."
	exit 1
	;;
esac

# ---------------------------------------------------------------------------
# THE CONFIG TABLE — dataset, then how many to KEEP per tier. 0 = tier off.
#
#                                daily  weekly  monthly
#
# The shape of it is the retention policy, decided 2026-08-23, and the reasoning
# per line is:
#
# tank/my_media — irreplaceable. Photos and video that get edited, and that
#   cannot be re-acquired from anywhere. No daily tier because it is not edited
#   daily; deep weekly and monthly tiers because the failure mode here is not
#   "I made a bad edit yesterday" but "I deleted a folder in March and noticed
#   in July". 8 weekly + 6 monthly is roughly six months of coverage, and
#   combined with skip-if-unchanged it stretches to years on a dataset that
#   genuinely never changes. Raising monthly to 12 buys a full year and costs
#   nothing; it is one number.
#
# tank/documents — the only dataset here with real churn, and small files, so
#   the daily tier is worth having and a week is too coarse a granularity to
#   recover from. 7 daily + 4 weekly + 6 monthly.
#
# tank/media — re-downloadable by definition, which is the whole reason it is a
#   separate dataset from my_media. Two weeklies, purely so that an `rm -rf`
#   pointed at the wrong path is a five-minute fix rather than a re-download
#   weekend. No monthly: paying retention for something replaceable is the one
#   thing this dataset exists to avoid.
#
# Three datasets, not four: tank/backups was destroyed 2026-08-23. It was empty
# and had no defined job, and it did not fit the axis the rest of the layout is
# organised on — replaceability. "Backups" is a category of content, not a
# category of how hard something is to get back, so there was no principled
# retention number to give it. If a Time Machine target is ever wanted, it gets
# created then, with a quota, rather than left standing as a name with no work.
#
# Adding a dataset here means adding it to tests/snapshot-retention/ too: the
# keep counts are duplicated there on purpose, and ALL_DS drives its write loop.
# ---------------------------------------------------------------------------

process_dataset tank/my_media    0  8  6
process_dataset tank/documents   7  4  6
process_dataset tank/media       0  2  0

# ---------------------------------------------------------------------------
# Summary, space accounting, and the heartbeat.
# ---------------------------------------------------------------------------

log "took $n_taken, pruned $n_pruned, skipped-unchanged $n_skipped, held $n_held, failed $n_failed, missing-datasets $n_missing"

# The number that bounds the whole policy. Retention is only a guess until this
# has real data behind it; it is in Standing checks for that reason.
log "usedbysnapshots:"
"$ZFS" list -o name,used,usedbysnapshots,usedbydataset,written -r "$POOL" >>"$LOG" 2>&1

verdict="took $n_taken, pruned $n_pruned, unchanged $n_skipped"
echo "$(date '+%Y-%m-%d %H:%M:%S') $verdict" >"$STATE"

rc=0
if [ "$n_failed" -gt 0 ]; then
	alert "ERRORS: $n_failed snapshot/prune operations failed." "$FAILURES"
	rc=2
elif [ "$n_missing" -gt 0 ]; then
	rc=3
fi

# Heartbeat. Its own timestamp file rather than the monthly tier, because with
# skip-if-unchanged a quiet dataset never takes a monthly and a heartbeat hung
# off that would go silent exactly when everything is fine.
if [ "$DRY_RUN" != 1 ] && [ "$rc" -eq 0 ]; then
	hb_age=$HEARTBEAT_SECS
	if [ -f "$HEARTBEAT" ]; then
		hb_mtime=$(stat -f %m "$HEARTBEAT" 2>/dev/null)
		case "$hb_mtime" in
		'' | *[!0-9]*) ;;
		*) hb_age=$((NOW - hb_mtime)) ;;
		esac
	fi
	if [ "$hb_age" -ge "$HEARTBEAT_SECS" ]; then
		notify "tank-snapshot: $POOL on $(hostname -s) — monthly heartbeat" \
			"$verdict

$("$ZFS" list -o name,used,usedbysnapshots,written -r "$POOL" 2>&1)"
		: >"$HEARTBEAT"
	fi
fi

log "--- done (exit $rc) ---"
exit "$rc"
