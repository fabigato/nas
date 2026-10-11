#!/bin/sh
#
# tank-offsite.sh — back `tank` up to an encrypted restic repository in S3
# Glacier Deep Archive. Copy 3: the only one that survives the room.
#
# WHAT THIS IS FOR
# `tank` covers a drive dying. Snapshots cover you. `tankbak` covers the
# enclosure and the machine — but it lives in the same building, so it does not
# cover fire, flood or theft of the room. This does, and it is the last copy in
# the chain.
#
# --- DESIGN ---------------------------------------------------------------
#
# 1. ONE DAEMON, FIRING DAILY, DECIDING DUE-NESS FROM AGE. NOT A CALENDAR.
#
# The obvious build is two plists — monthly for my_media, weekly for documents.
# tank-snapshot.sh already found the hole in that: launchd runs a missed
# StartCalendarInterval job ONCE at the next wake, so a monthly job whose window
# is missed is silently skipped for a month, and a weekly one for a week. On a
# job whose whole purpose is the copy of last resort, "silently skipped" is the
# worst available failure.
#
# So: one daily job. A target is due when the last SUCCESSFUL run for it is
# older than its interval. Immune to sleep, missed runs, reboots and clock
# changes, and idempotent — kickstart it twice and the second run does nothing.
#
# The slack term is the same fix for the same reason: if the daily fire lands
# 2 seconds early, age is 2591998 < 2592000, "not due", and a whole month is
# skipped. A target may be due half a run-period early.
#
# 2. IT REFUSES TO RUN AGAINST AN UNMOUNTED DATASET, AND THIS IS THE MOST
#    IMPORTANT GUARD IN THE FILE.
#
# /Volumes/tank/my_media with the pool exported is not an error — it is an empty
# directory, or does not exist. restic would read that as "the library is now
# empty", record a snapshot saying so, and succeed. Every later restore would
# then start from a snapshot that says you own nothing.
#
# This is exactly the failure local.jellyfin guards against by refusing to start
# unless both datasets are mounted, for the same reason: Jellyfin reads a missing
# library path as an emptied library and purges its database. Same trap, same
# answer. Checking `zfs get mounted` is not quite enough either — a mounted but
# wrong filesystem passes that — so the directory must also be non-empty.
#
# Versioned snapshots mean such a run would be recoverable rather than fatal,
# which is a large part of why this is not a mirror. It is still not allowed to
# happen.
#
# 3. IT DEFERS WHILE A SCRUB OR RESILVER IS RUNNING.
#
# A full scrub is 10-20 hours on this enclosure and runs monthly on the 1st at
# 03:00. Rather than choosing a day and hoping the two never meet, the job asks.
# Because due-ness is age-based, deferring a day costs nothing at all — which is
# the second dividend of not using a calendar.
#
# 4. ONE REPOSITORY FOR BOTH DATASETS.
#
# Not one per dataset. Chunks are shared across everything in a repository, so a
# file moved from documents into my_media re-uploads nothing, and there is one
# password to escrow, one prune to run and one thing to restore-test. The two
# datasets are separated by --tag and by path, which is all `forget --group-by
# paths` needs to apply different retention to each.
#
# 5. RESTIC CHOOSES THE STORAGE CLASS, NOT A LIFECYCLE RULE, BECAUSE ONLY
#    RESTIC KNOWS WHICH PACKS ARE TREES.
#
# restic keeps two kinds of pack under data/: content (file bytes) and trees
# (the directory structure of every snapshot). Trees are read by EVERYTHING —
# check, prune, ls, find, the parent comparison in backup, and every restore,
# even of one file. Content is read only by a restore.
#
# The first design sent all of data/ to Deep Archive after 7 days with a
# lifecycle rule, on the belief that nothing under data/ was read routinely.
# The tree packs proved it wrong: on 2026-10-10, the first night the seed's
# trees had gone cold, `restic check` failed on every snapshot with "The
# operation is not valid for the object's storage class". From the outside of
# the bucket a tree pack and a content pack are indistinguishable, so no
# lifecycle filter can tell them apart.
#
# restic can. With -o s3.storage-class=DEEP_ARCHIVE it puts content packs in
# Deep Archive at upload and everything else — trees included — in Standard.
# Read from restic 0.19.1's source, not assumed: useStorageClass applies an
# archive class only to `PackFile && !IsMetadata`. `restic options` does not
# list DEEP_ARCHIVE among the values, which is why this needed checking.
#
# WHAT THAT COST: the free read-back check. It restored a few of the files a
# run had just changed, which worked because their packs stayed in Standard
# for the 7 days before the transition. Content now goes cold at upload, so
# there is nothing warm to read back. `restic backup` exiting 0 proves the
# upload, not the archive, and that gap is real: it is covered by the
# quarterly restore test (README), which thaws what it reads.
#
# 6. NOTIFICATIONS: FAILURES ALWAYS, PLUS A HEARTBEAT ON ITS OWN CLOCK.
#
# tank-scrub.sh posts every run because at 12 runs a year the message IS the
# heartbeat. That does not transfer here: this fires 365 times a year and does
# real work on ~64 of them, and one message a week is noise. Noise is how a real
# alert gets missed. So: every failure, plus one summary whenever the last
# summary went out more than 30 days ago.
#
# Deliberately NOT hung off "a backup happened". With --skip-if-unchanged, a
# month in which my_media did not change produces no snapshot — so a heartbeat
# tied to that would go quiet exactly when everything is fine, inverting the
# signal. Same trap tank-snapshot.sh documented for the monthly tier.
#
# --- USAGE ---------------------------------------------------------------
#
# Installed as local.tank-offsite, daily at 01:30. Also runnable by hand:
#
#   sudo sh tank-offsite.sh                 # normal run: back up what is due
#   sudo sh tank-offsite.sh --dry-run       # decide and print, upload nothing
#   sudo sh tank-offsite.sh --force         # ignore due-ness, back up everything
#   sudo sh tank-offsite.sh --only my_media # one target, named as in the table
#   sudo sh tank-offsite.sh --seed          # unthrottled: SATURATES the 29 Mbit
#                                           # uplink for ~37 h. Only when nobody
#                                           # needs the connection.
#   sudo sh tank-offsite.sh --list          # what is in the repository
#   pass show nas/offsite-prune-aws |
#     sudo sh tank-offsite.sh --drop <id>   # forget one snapshot you know is
#                                           # junk, then reclaim it. Needs the
#                                           # prune credential on stdin.
#   pass show nas/offsite-prune-aws |
#     sudo sh tank-offsite.sh --fix-classes # put every pack in the class
#                                           # DESIGN 5 says it belongs in.
#                                           # Re-run until it says done.
#
# Exit codes:
#   0  ran, or correctly had nothing to do
#   1  refused to start (pool, mount, config, tooling)
#   2  a backup or check failed, or a snapshot is incomplete — READ THE LOG
#   3  deferred (a scrub is running, or another run still has the lock), or
#      --fix-classes is waiting on a Glacier thaw — run it again later

set -u

# ABSOLUTE PATHS, because a LaunchDaemon gets a minimal PATH and no user
# environment. tank-boot-unlock.sh cost three cold boots to learn this.
#
# Overridable ONLY so the test suite can point them at stubs. That is a better
# testability hook than a skip-the-guards flag: the guards still execute, in
# full, against a filesystem a test can control. A bypass flag would leave the
# most important guard in the file permanently untested.
ZFS=${TANK_OFFSITE_ZFS:-/usr/local/zfs/bin/zfs}
ZPOOL=${TANK_OFFSITE_ZPOOL:-/usr/local/zfs/bin/zpool}
RESTIC=${TANK_OFFSITE_RESTIC:-/opt/homebrew/bin/restic}
# Only used for the storage-class invariant below. restic cannot report an
# object's storage class, so this is the one thing that needs the AWS CLI.
AWS_CLI=${TANK_OFFSITE_AWS:-/opt/homebrew/bin/aws}
# Reads restic's index to tell tree packs from content packs. Ships with macOS.
JQ=${TANK_OFFSITE_JQ:-/usr/bin/jq}

POOL=${TANK_OFFSITE_POOL:-tank}
MOUNT_ROOT=${TANK_OFFSITE_MOUNT_ROOT:-/Volumes/tank}

CONF_DIR=${TANK_OFFSITE_CONF_DIR:-/etc/tank-offsite}
STATE_DIR=${TANK_OFFSITE_STATE_DIR:-/var/lib/tank-offsite}
LOG=${TANK_OFFSITE_LOG:-/var/log/tank-offsite.log}
LAST=${TANK_OFFSITE_LAST:-/var/log/tank-offsite.last}
HEARTBEAT=${TANK_OFFSITE_HEARTBEAT:-/var/log/tank-offsite.heartbeat}

# Upload ceiling in KiB/s. 2500 KiB/s is ~20 Mbit of the 29 Mbit uplink, which
# leaves the line usable if a big month runs past breakfast.
#
# MEASURED 2026-09-30, and it beat the estimate. The 490 GB seed ran at the
# full unthrottled rate straight through a working day of video calls with no
# noticeable effect. So the warning an earlier version of this comment carried
# — that ~20 Mbit of a 29 Mbit uplink would make calls stutter — was wrong on
# this line, and the router evidently handles the queueing better than a
# generic consumer setup would.
#
# The mechanism behind that warning is still real and worth keeping in mind if
# the connection ever changes: saturating the UPLINK degrades DOWNLOAD too,
# because ACKs for inbound traffic queue behind the outbound flood. It just is
# not biting here.
#
# Figures for a 490 GB transfer on this connection:
#   --seed (unthrottled, ~29 Mbit)  ~37 h   measured fine during calls
#   2500 KiB/s (~20 Mbit)           ~54 h   the default
#   1800 KiB/s (~15 Mbit)           ~74 h   if the line ever gets busier
LIMIT_UP=${TANK_OFFSITE_LIMIT_UP:-2500}

# Pack size in MiB, against a default of 16. Four times fewer objects means four
# times less of Deep Archive's ~40 KB per-object overhead and four times fewer
# PUTs on the seed. The cost is downloading more to retrieve one small file,
# which is the right trade for an archive nobody browses casually.
PACK_SIZE=${TANK_OFFSITE_PACK_SIZE:-64}

# Where content packs go at upload. See DESIGN 5: restic applies this to
# content only and keeps trees in Standard, which is the whole point.
STORAGE_CLASS=${TANK_OFFSITE_STORAGE_CLASS:-DEEP_ARCHIVE}

# A run holds this for its whole duration so the next nightly fire defers
# instead of colliding. /var/run is cleared at boot, which disposes of a lock
# orphaned by a panic for free.
LOCKDIR=${TANK_OFFSITE_LOCKDIR:-/var/run/tank-offsite.lock}

# Where --drop reads its typed confirmation. Not stdin: that carries the prune
# credential.
DROP_TTY=${TANK_OFFSITE_DROP_TTY:-/dev/tty}

HEARTBEAT_DAYS=${TANK_OFFSITE_HEARTBEAT_DAYS:-30}
ZEDRC=${TANK_OFFSITE_ZEDRC:-/etc/zfs/zed.d/zed.rc}
NOTIFY_MAX_CHARS=1500

DRY_RUN=0
FORCE=0
SEED=0
ONLY=
MODE=backup
DROP_ID=

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	--seed) SEED=1; FORCE=1 ;;
	--list) MODE=list ;;
	--fix-classes) MODE=fix-classes ;;
	--only)
		shift
		[ $# -gt 0 ] || { echo "--only needs a dataset name" >&2; exit 1; }
		ONLY=$1
		;;
	--drop)
		shift
		[ $# -gt 0 ] || { echo "--drop needs a snapshot id" >&2; exit 1; }
		MODE=drop
		DROP_ID=$1
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 1
		;;
	esac
	shift
done

# ---------------------------------------------------------------- the table

# WHAT GETS BACKED UP.  <path relative to $MOUNT_ROOT>  <interval in days>
#
# Paths, not datasets, so a chosen folder inside an otherwise-excluded dataset
# can be included. `media` as a whole is re-downloadable and has no offsite
# priority — that is the entire reason my_media was split off it — but
# individual folders in there can still be worth keeping, and this is how.
#
# my_media monthly: a library it took a decade to build, edited maybe twice a
# year. documents weekly: small, but the only dataset here with real churn, and
# tank-snapshot.sh already decided a week is the coarsest granularity worth
# having on it. At 1-2 GB the weekly cadence costs fractions of a cent.
#
# THIS LIVES IN A CONFIG FILE, unlike tank-snapshot.sh's retention table, and
# the difference is deliberate. That table is policy that changes about once a
# year, so keeping it in the script (and duplicating it in the test, so a
# disagreement means a typo) is right. This is a list of folders that will grow
# whenever you decide another one matters, and making that a script edit plus a
# reinstall is friction in front of the one action that adds protection.
#
# Edit /etc/tank-offsite/targets; the built-in list below is only the fallback
# for a machine where that file does not exist yet.
TARGETS_FILE=${TANK_OFFSITE_TARGETS:-$CONF_DIR/targets}
EXCLUDE_FILE=${TANK_OFFSITE_EXCLUDE:-$CONF_DIR/exclude}

targets() {
	if [ -f "$TARGETS_FILE" ]; then
		sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$TARGETS_FILE" | grep -v '^$'
	else
		cat <<-TBL
			my_media 30
			documents 7
		TBL
	fi
}

# ------------------------------------------------------------------ helpers

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Reuse zed's webhook so delivery is configured in exactly one place, and check
# the HTTP status ourselves. tank-scrub.sh measured why: Discord returns 401 on
# a revoked token with a flat {"message": ...} body, curl exits 0 without -f,
# and zed's Slack-shaped error check does not match — so zed counts a rejected
# post as delivered. The channel that reports this daemon's failures must be able
# to detect its own.
notify() {
	nurl=$(awk -F'"' '/^ZED_SLACK_WEBHOOK_URL=/ { print $2; exit }' "$ZEDRC" 2>/dev/null)
	if [ -z "$nurl" ]; then
		log "  notify: no channel set (ZED_SLACK_WEBHOOK_URL in $ZEDRC) — log only"
		return 0
	fi

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
		log "          The message above exists ONLY in this log."
		;;
	esac
}

alert() {
	log "$1"
	/usr/bin/logger -t tank-offsite -p daemon.err "$1"
	notify "tank-offsite: $POOL on $(hostname -s)" "$1${2:+

$2}"
}

die() {
	alert "REFUSED: $1"
	echo "REFUSED: $1" >"$LAST"
	exit "${2:-1}"
}

now() { date '+%s'; }

# Every pack id holding tree blobs, one per line, read from restic's index.
# restic never mixes trees and content in one pack. Returns 1 if ANY index file
# could not be read: a partial list would make a caller treat the missing tree
# packs as content, and --fix-classes would then send them to Deep Archive.
tree_packs() {
	tp_ids=$("$RESTIC" list index 2>/dev/null) || return 1
	[ -n "$tp_ids" ] || return 1
	for tp_id in $tp_ids; do
		# Captured, not piped: in `restic cat | jq` the status is jq's, and jq
		# succeeds on empty input. An index holding only content packs is
		# normal and prints nothing, so emptiness cannot be the error signal.
		tp_json=$("$RESTIC" cat index "$tp_id" 2>/dev/null) || return 1
		printf '%s' "$tp_json" |
			"$JQ" -r '.packs[] | select(any(.blobs[]; .type == "tree")) | .id' ||
			return 1
	done
}

# Joins tree_packs output ($1, a file) with a data/ listing on stdin
# (key<TAB>class per line) and prints what is in the wrong class:
#   tree<TAB>key       a tree pack out of Standard — breaks check, prune, restore
#   content<TAB>key    a content pack still in Standard — costs money, breaks nothing
misfiled_packs() {
	awk -F'\t' 'NR == FNR { tree[$1] = 1; next }
		$1 ~ /^data\// {
			n = split($1, p, "/")
			if (p[n] in tree) { if ($2 != "STANDARD") print "tree\t" $1 }
			else if ($2 == "STANDARD") print "content\t" $1
		}' "$1" -
}

# key<TAB>class for every object under data/. The CLI follows pagination itself.
list_data_classes() {
	"$AWS_CLI" s3api list-objects-v2 --bucket "$BUCKET" --prefix data/ \
		--query 'Contents[].[Key,StorageClass]' --output text
}

# The prune credential, read from stdin for one command and never written down.
# $1 = the command line to show in the refusal, e.g. "--drop 1a2b3c4d".
take_prune_credential() {
	[ -t 0 ] && die "${1%% *} needs the prune credential on stdin:
  pass show nas/offsite-prune-aws | sudo $0 $1"
	tpc_creds=$(cat)
	tpc_key=$(printf '%s\n' "$tpc_creds" | awk -F= '/^AWS_ACCESS_KEY_ID=/ { print $2; exit }')
	tpc_secret=$(printf '%s\n' "$tpc_creds" | awk -F= '/^AWS_SECRET_ACCESS_KEY=/ { print $2; exit }')
	unset tpc_creds
	[ -n "$tpc_key" ] && [ -n "$tpc_secret" ] ||
		die "${1%% *}: stdin did not hold AWS_ACCESS_KEY_ID= and AWS_SECRET_ACCESS_KEY= lines — nothing done"
	[ "$tpc_key" != "$AWS_ACCESS_KEY_ID" ] ||
		die "${1%% *}: that is the backup credential, which cannot delete or thaw — pipe in nas/offsite-prune-aws"
	AWS_ACCESS_KEY_ID=$tpc_key
	AWS_SECRET_ACCESS_KEY=$tpc_secret
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

# ---------------------------------------------------------------- preflight

mkdir -p "$STATE_DIR" 2>/dev/null
[ -d "$STATE_DIR" ] || die "cannot create $STATE_DIR"

log "=== run start (dry_run=$DRY_RUN force=$FORCE seed=$SEED mode=$MODE) ==="

# ONE RUN AT A TIME, AND A SECOND ONE DEFERS RATHER THAN FAILING.
#
# This is not about the seed. It is about ordinary operation: this job fires
# daily, and a month in which 200 GB of video was added takes ~30 hours at the
# throttled rate. That run is still going when tomorrow's fire lands. Without a
# lock, the second run reaches restic, gets "repository is already locked",
# and — by design — ALERTS. So a large but completely healthy month would post
# a failure to Discord every night until it finished.
#
# That is the cry-wolf failure again, and it is worse here than a missed
# message: the channel that reports real trouble would be the one crying.
# A concurrent run is not a fault, it is a schedule doing its job. Exit 3,
# quietly, and try again tomorrow.
#
# mkdir is the atomic primitive; macOS has no flock(1). A PID file inside it
# distinguishes "still running" from "died without cleaning up", because a
# stale lock that blocks every future run forever would be a worse bug than
# the one this fixes.
HAVE_LOCK=0
release_lock() { [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCKDIR"; }
trap release_lock EXIT INT TERM

if mkdir "$LOCKDIR" 2>/dev/null; then
	HAVE_LOCK=1
	echo $$ >"$LOCKDIR/pid"
else
	OTHER=$(cat "$LOCKDIR/pid" 2>/dev/null)
	if [ -n "$OTHER" ] && kill -0 "$OTHER" 2>/dev/null; then
		log "  run $OTHER is still going — deferring, will retry tomorrow"
		echo "deferred: run $OTHER still in progress" >"$LAST"
		exit 3
	fi
	log "  clearing a stale lock (pid ${OTHER:-unknown} is gone)"
	rm -rf "$LOCKDIR"
	mkdir "$LOCKDIR" 2>/dev/null || die "cannot take the lock at $LOCKDIR"
	HAVE_LOCK=1
	echo $$ >"$LOCKDIR/pid"
fi

[ -x "$RESTIC" ] || die "restic not found at $RESTIC — brew install restic"
[ -x "$ZPOOL" ] || die "zpool not found at $ZPOOL"

[ -f "$CONF_DIR/env" ] || die "$CONF_DIR/env missing — run bootstrap-offsite.sh first"
[ -f "$CONF_DIR/repo.pass" ] || die "$CONF_DIR/repo.pass missing — run bootstrap-offsite.sh first"
[ -f "$CONF_DIR/backup.env" ] || die "$CONF_DIR/backup.env missing — run bootstrap-offsite.sh first"

BUCKET=$(awk -F= '/^OFFSITE_BUCKET=/ { print $2; exit }' "$CONF_DIR/env")
RESTIC_REPOSITORY=$(awk -F= '/^RESTIC_REPOSITORY=/ { print $2; exit }' "$CONF_DIR/env")
[ -n "$RESTIC_REPOSITORY" ] || die "no RESTIC_REPOSITORY in $CONF_DIR/env"
AWS_ACCESS_KEY_ID=$(awk -F= '/^AWS_ACCESS_KEY_ID=/ { print $2; exit }' "$CONF_DIR/backup.env")
AWS_SECRET_ACCESS_KEY=$(awk -F= '/^AWS_SECRET_ACCESS_KEY=/ { print $2; exit }' "$CONF_DIR/backup.env")
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] ||
	die "$CONF_DIR/backup.env is malformed"

RESTIC_PASSWORD_FILE=$CONF_DIR/repo.pass
# Keep restic's cache in a fixed place. Left to itself it follows $HOME, which
# under launchd is not what it is in a terminal — so a hand-run and a daemon run
# would use different caches and each would rebuild the other's work from S3.
RESTIC_CACHE_DIR=${TANK_OFFSITE_CACHE_DIR:-/var/cache/tank-offsite}
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
mkdir -p "$RESTIC_CACHE_DIR" 2>/dev/null

# Probe for --skip-if-unchanged rather than assuming the installed restic has
# it. It landed in 0.17; on an older build the flag is a hard error and every
# run would fail. Measured, not assumed.
SKIP_UNCHANGED=
if "$RESTIC" backup --help 2>&1 | grep -q -- '--skip-if-unchanged'; then
	SKIP_UNCHANGED=--skip-if-unchanged
else
	log "  note: this restic has no --skip-if-unchanged; an unchanged run will"
	log "        still record a snapshot. Harmless, just less tidy."
fi

# ------------------------------------------------------------------- guards

pool_state() { "$ZPOOL" list -H -o health "$POOL" 2>/dev/null; }

# Reading pool state is safe even on a suspended pool — the 2026-08-17 pull test
# confirmed `zpool status` keeps answering with a drive physically removed.
PSTATE=$(pool_state)
case "$PSTATE" in
ONLINE | DEGRADED) log "  pool $POOL: $PSTATE" ;;
"") die "pool $POOL is not imported" ;;
*) die "pool $POOL is $PSTATE — refusing to read from it" ;;
esac

# Defer rather than fight the scrub. Age-based due-ness makes a deferral free.
if "$ZPOOL" status "$POOL" 2>/dev/null | grep -qE '(scrub|resilver) in progress'; then
	log "  a scan is in progress — deferring, will retry tomorrow"
	echo "deferred: scan in progress" >"$LAST"
	exit 3
fi

# See DESIGN 2. This is the guard that matters.
# Returns 1 rather than calling die(), so one bad target does not take the
# others down with it. It still alerts — the caller marks the target FAILED.
# $1 = dataset (first path component), $2 = full relative path
check_mounted() {
	cm_ds=$1
	cm_path=$2
	cm_mounted=$("$ZFS" get -H -o value mounted "$POOL/$cm_ds" 2>/dev/null)
	if [ "$cm_mounted" != yes ]; then
		alert "$cm_path: $POOL/$cm_ds is not mounted (mounted=$cm_mounted)." \
			"Backing up an unmounted mountpoint would record a snapshot saying
the dataset is empty. Skipping this target."
		return 1
	fi
	if [ ! -d "$MOUNT_ROOT/$cm_path" ]; then
		alert "$cm_path: $MOUNT_ROOT/$cm_path does not exist." \
			"$POOL/$cm_ds is mounted, so this is a configured path that is gone
— check $TARGETS_FILE. Data you believe is protected is not."
		return 1
	fi
	# `mounted=yes` does not prove the right thing is there. An empty directory
	# is the exact shape of the disaster this guard exists for, so check it.
	if [ -z "$(ls -A "$MOUNT_ROOT/$cm_path" 2>/dev/null)" ]; then
		alert "$cm_path: $MOUNT_ROOT/$cm_path is EMPTY." \
			"Refusing this target: recording an empty tree as the current state
is how a backup deletes your library."
		return 1
	fi
	return 0
}

# CLEAR LOCKS LEFT BY A DEAD PROCESS, AND YES, AUTOMATICALLY.
#
# An earlier version of this file said an automatic unlock "would break the one
# thing stopping two runs from writing at once". That was wrong on both halves.
# The thing stopping two runs is $LOCKDIR above, taken before any of this; and
# plain `restic unlock` — no --remove-all — only removes locks whose creating
# process is GONE, which is the same liveness test $LOCKDIR already does. A
# lock held by a live restic is left exactly where it is.
#
# Needed because something in the 2026-10-03 run left a lock behind and it was
# still there 23 minutes later, long after that PID had exited. --retry-lock
# does not help with that: waiting five minutes for a lock nobody will ever
# release only fails more slowly. restic takes SHARED locks for backup and
# restore and an EXCLUSIVE one for check, so a leftover shared lock is
# invisible to every backup and restore and blocks only the check — which is
# why it surfaced as "your repository is broken" rather than as a stuck run.
UNLOCK_OUT=$("$RESTIC" unlock 2>&1)
case "$UNLOCK_OUT" in
*"successfully removed"*)
	log "  cleared a stale restic lock — $UNLOCK_OUT"
	log "    (a previous run exited without releasing it; harmless, but if this"
	log "     appears every run something is dying mid-command — check above.)"
	;;
esac

# --------------------------------------------------------------- list / drop

if [ "$MODE" = list ]; then
	"$RESTIC" snapshots --group-by paths 2>&1 | tee -a "$LOG"
	exit $?
fi

if [ "$MODE" = drop ]; then
	log "  dropping snapshot $DROP_ID"
	# Show ONLY the snapshot being dropped. This used to print every snapshot
	# in the repository under "This is not reversible", which on 2026-10-09
	# read as if my_media were about to go too. restic exits 0 for an unknown
	# id, so match on the JSON rather than the exit code.
	drop_n=$("$RESTIC" snapshots --json "$DROP_ID" 2>/dev/null | grep -o '"short_id"' | wc -l | tr -d ' ')
	[ "$drop_n" = 1 ] || die "--drop: \"$DROP_ID\" matches $drop_n snapshots, not exactly one — nothing done"
	drop_total=$("$RESTIC" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l | tr -d ' ')
	echo "About to forget THIS ONE snapshot. Not reversible:"
	echo
	"$RESTIC" snapshots "$DROP_ID" 2>&1 | sed 's/^/  /'
	echo
	echo "The other $((drop_total - 1)) snapshot(s) in the repository are untouched, and"
	echo "so is every piece of data they use. Prune then deletes only data that no"
	echo "remaining snapshot refers to — if another snapshot of the same folder"
	echo "shares this one's data, nothing is freed until that one goes too."
	echo
	# stdin carries the prune credential, so the confirmation comes from the
	# terminal itself.
	printf 'Type the snapshot id again to confirm: '
	read -r confirm <"$DROP_TTY"
	[ "$confirm" = "$DROP_ID" ] || die "confirmation did not match — nothing done"
	if [ "$DRY_RUN" = 1 ]; then
		echo "[dry-run] restic forget $DROP_ID && restic prune --max-repack-size 0"
		exit 0
	fi

	# THE BACKUP CREDENTIAL CANNOT DELETE, ON PURPOSE. It has s3:DeleteObject on
	# locks/ only, so ransomware holding this machine cannot take copy 3 with
	# it. Deleting needs tank-offsite-prune, whose key lives only in `pass` and
	# is piped in for this one command — never written here. The first --drop
	# ever run (2026-10-09) used the backup credential and got AccessDenied.
	take_prune_credential "--drop $DROP_ID"

	# Captured, not piped into tee. `restic forget | tee` reports tee's exit
	# status, so on 2026-10-09 an AccessDenied forget was followed by a prune
	# and "dropped" in the log.
	drop_out=$("$RESTIC" forget "$DROP_ID" 2>&1); drop_rc=$?
	printf '%s\n' "$drop_out" | tee -a "$LOG"
	[ "$drop_rc" = 0 ] || die "forget $DROP_ID failed (rc=$drop_rc) — nothing was deleted, prune not run" 2
	# --max-repack-size 0 keeps prune from repacking partially-used packs, which
	# would mean downloading them out of Deep Archive. Delete-only reclaim. The
	# storage class is passed anyway, so that if a future prune does write a
	# pack, it lands where an upload would have put it (DESIGN 5).
	drop_out=$("$RESTIC" prune -o s3.storage-class="$STORAGE_CLASS" --max-repack-size 0 2>&1); drop_rc=$?
	printf '%s\n' "$drop_out" | tee -a "$LOG"
	[ "$drop_rc" = 0 ] || die "prune after forgetting $DROP_ID failed (rc=$drop_rc) — the snapshot is gone, its data may not be" 2
	log "  dropped $DROP_ID"
	exit 0
fi

# ------------------------------------------------------------- fix-classes

# Puts every pack in the class DESIGN 5 says it belongs in, and is safe to run
# at any time: it only moves what is in the wrong place.
#
#   tree pack, cold     ask S3 to thaw it (Standard tier, <= 12 h), and on a
#                       later run, once thawed, copy it over itself as STANDARD
#   content, Standard   copy it over itself as DEEP_ARCHIVE
#
# Written for the 2026-10-10 repair, when the lifecycle rule had already sent
# the seed's trees cold and left the last week's content warm. Kept because the
# nightly invariant below names it as the fix if that ever happens again.
#
# Needs the prune credential: the backup credential cannot issue a Glacier
# restore. Bucket versioning keeps the replaced copy as a noncurrent version for
# 180 days, so a mistake here is recoverable — and costs that copy's storage
# for those 180 days.
if [ "$MODE" = fix-classes ]; then
	[ -n "$BUCKET" ] || die "--fix-classes: no OFFSITE_BUCKET in $CONF_DIR/env"
	[ -x "$AWS_CLI" ] || die "--fix-classes: $AWS_CLI not found"
	[ -x "$JQ" ] || die "--fix-classes: $JQ not found"
	# A dry run only lists and reads, which the backup credential can do.
	[ "$DRY_RUN" = 1 ] || take_prune_credential --fix-classes

	FC_TMP=$(mktemp -d /tmp/tank-offsite-fix.XXXXXX) || die "cannot make a temp dir"
	trap 'rm -rf "$FC_TMP"; release_lock' EXIT INT TERM
	fc_say() { echo "$*"; log "  $*"; }

	# The one refusal that protects the repository from this command. Without
	# the complete list of tree packs, a tree pack is indistinguishable from
	# content and would be sent to Deep Archive — the very damage being fixed.
	if ! tree_packs >"$FC_TMP/trees" || [ ! -s "$FC_TMP/trees" ]; then
		die "--fix-classes: could not read restic's index, so tree packs cannot be told from content — nothing done" 2
	fi
	list_data_classes >"$FC_TMP/objects" 2>"$FC_TMP/err" ||
		die "--fix-classes: listing data/ failed — $(tail -1 "$FC_TMP/err")" 2
	misfiled_packs "$FC_TMP/trees" <"$FC_TMP/objects" >"$FC_TMP/plan"

	fc_say "$(wc -l <"$FC_TMP/trees" | tr -d ' ') tree pack(s) in the index; $(grep -c '^tree' "$FC_TMP/plan") cold, $(grep -c '^content' "$FC_TMP/plan") content pack(s) still in Standard"

	fc_thawing=0
	fc_moved=0
	fc_err=0
	while IFS="$(printf '\t')" read -r fc_kind fc_key; do
		if [ "$fc_kind" = content ]; then
			if [ "$DRY_RUN" = 1 ]; then
				fc_say "[dry-run] $fc_key: content, would copy to $STORAGE_CLASS"
				continue
			fi
			if "$AWS_CLI" s3api copy-object --bucket "$BUCKET" --key "$fc_key" \
				--copy-source "$BUCKET/$fc_key" --storage-class "$STORAGE_CLASS" \
				--metadata-directive COPY >/dev/null 2>"$FC_TMP/err"; then
				fc_moved=$((fc_moved + 1))
			else
				fc_say "$fc_key: copy to $STORAGE_CLASS FAILED — $(tail -1 "$FC_TMP/err")"
				fc_err=$((fc_err + 1))
			fi
			continue
		fi

		# A cold tree pack. Where is its thaw?
		#   None                            not asked for yet
		#   ongoing-request="true"          asked for, not ready
		#   ongoing-request="false", ...    readable now, until expiry-date
		fc_restore=$("$AWS_CLI" s3api head-object --bucket "$BUCKET" --key "$fc_key" \
			--query Restore --output text 2>"$FC_TMP/err") || {
			fc_say "$fc_key: head-object FAILED — $(tail -1 "$FC_TMP/err")"
			fc_err=$((fc_err + 1))
			continue
		}
		case "$fc_restore" in
		*'ongoing-request="false"'*)
			if [ "$DRY_RUN" = 1 ]; then
				fc_say "[dry-run] $fc_key: tree, thawed, would copy to STANDARD"
				continue
			fi
			if "$AWS_CLI" s3api copy-object --bucket "$BUCKET" --key "$fc_key" \
				--copy-source "$BUCKET/$fc_key" --storage-class STANDARD \
				--metadata-directive COPY >/dev/null 2>"$FC_TMP/err"; then
				fc_say "$fc_key: tree, back in STANDARD"
				fc_moved=$((fc_moved + 1))
			else
				fc_say "$fc_key: copy to STANDARD FAILED — $(tail -1 "$FC_TMP/err")"
				fc_err=$((fc_err + 1))
			fi
			;;
		*'ongoing-request="true"'*)
			fc_say "$fc_key: tree, still thawing"
			fc_thawing=$((fc_thawing + 1))
			;;
		*)
			if [ "$DRY_RUN" = 1 ]; then
				fc_say "[dry-run] $fc_key: tree, cold, would request a thaw"
				continue
			fi
			# Standard tier, not Bulk: tree packs are few and small, so the
			# price difference is cents and the wait is 12 h instead of 48.
			# Days=7 so a thaw that finishes on a Friday survives the weekend.
			if "$AWS_CLI" s3api restore-object --bucket "$BUCKET" --key "$fc_key" \
				--restore-request 'Days=7,GlacierJobParameters={Tier=Standard}' \
				>/dev/null 2>"$FC_TMP/err"; then
				fc_say "$fc_key: tree, thaw requested"
				fc_thawing=$((fc_thawing + 1))
			else
				fc_say "$fc_key: thaw request FAILED — $(tail -1 "$FC_TMP/err")"
				fc_err=$((fc_err + 1))
			fi
			;;
		esac
	done <"$FC_TMP/plan"

	[ "$DRY_RUN" = 1 ] && exit 0
	fc_say "moved $fc_moved pack(s); $fc_thawing tree pack(s) thawing; $fc_err error(s)"
	[ "$fc_err" = 0 ] || exit 2
	if [ "$fc_thawing" -gt 0 ]; then
		fc_say "Run this again in ~12 hours to move the thawed tree packs back to STANDARD."
		exit 3
	fi
	fc_say "Every pack is in its class."
	exit 0
fi

# ------------------------------------------------------------------- backup

RAN=
FAILED=
WARNED=
SKIPPED=

# THE LOOP IS FED BY REDIRECTION, NOT BY A PIPE, AND THAT IS NOT A STYLE CHOICE.
#
# `targets | while ...` runs the loop body in a subshell, and `die`'s exit then
# leaves only the SUBSHELL. Measured against a deliberately broken copy in
# tests/offsite-rehearsal/smoke-local.sh, the consequence is not what a first
# reading suggests, and the precise version is the useful one:
#
# The guard still fires. It logs, it alerts, and it does stop that dataset from
# being backed up — so no empty snapshot is ever recorded. What breaks is
# everything downstream. The loop ABORTS, silently skipping every dataset after
# the one that refused; RAN and FAILED are discarded at `done`, so the epilogue
# reads `ran:[none] failed:[none]`; and the script EXITS 0. The 30-day heartbeat
# then posts that summary as though it were healthy.
#
# So the bug does not corrupt the archive. It converts "I refused to run" into
# "I ran and all was well" — which is the exact ambiguity DESIGN 6 exists to
# prevent, arriving through the back door. A backup that reports success while
# having done nothing is the failure this whole file is written against.
TABLE=$(mktemp /tmp/tank-offsite-table.XXXXXX) || die "cannot make a temp file"
targets >"$TABLE"

# TWO KINDS OF WRONG, HANDLED TWO DIFFERENT WAYS. THE SPLIT IS THE POINT.
#
# SYNTAX is checked here, up front, and refuses the whole run. A line that does
# not parse means the table cannot be trusted at all — we do not know what was
# meant, so acting on the lines that happen to parse would be guessing.
#
# EXISTENCE is checked per target, further down, and takes out only that
# target. An earlier version refused the whole run for a missing path, on the
# grounds that a path you believe is protected and is not is the quietest
# possible failure. That reasoning is right and the conclusion was wrong: it
# means renaming one folder inside `media` silently stops backing up my_media
# too, so a trivial config drift costs you EVERY offsite backup until someone
# notices. You still get the alert either way — the only thing refusing
# everything adds is collateral.
#
# Partial protection beats none, and it is the same call tank-snapshot.sh makes
# when `written` is unreadable: fail in the direction that keeps data covered.
while read -r VPATH VDAYS; do
	[ -n "$VPATH" ] || continue
	case "$VPATH" in
	/* | *..*) die "$TARGETS_FILE: '$VPATH' must be relative to $MOUNT_ROOT and contain no .." ;;
	esac
	case "${VDAYS:-}" in
	'' | *[!0-9]*) die "$TARGETS_FILE: '$VPATH' has a bad interval '${VDAYS:-}' — want a number of days" ;;
	esac
done <"$TABLE"

if [ -n "$ONLY" ] && ! awk -v o="$ONLY" '$1 == o { f = 1 } END { exit !f }' "$TABLE"; then
	die "--only '$ONLY' matches nothing in $TARGETS_FILE"
fi

while read -r TPATH INTERVAL_DAYS; do
	[ -n "$TPATH" ] || continue
	if [ -n "$ONLY" ] && [ "$ONLY" != "$TPATH" ]; then
		continue
	fi

	# The dataset is the first path component — that is what `zfs get mounted`
	# understands. For a plain dataset target the two are the same string.
	DSET=${TPATH%%/*}
	# Slashes cannot go in a filename, so media/concerts becomes media_concerts.
	STATE=$STATE_DIR/$(printf '%s' "$TPATH" | tr / _).last
	INTERVAL=$((INTERVAL_DAYS * 86400))
	# Half a run-period of slack, so a fire landing seconds early does not skip
	# a whole interval. Half a day cannot let a target fire twice in one run.
	SLACK=43200

	LAST_RUN=0
	PARENT=
	if [ -f "$STATE" ]; then
		LAST_RUN=$(awk '{print $1; exit}' "$STATE" 2>/dev/null)
		PARENT=$(awk '{print $2; exit}' "$STATE" 2>/dev/null)
		case "$LAST_RUN" in
		'' | *[!0-9]*)
			# Unreadable state means we cannot tell whether a backup is due.
			# Fail OPEN and back up: a redundant run costs bandwidth, a skipped
			# one costs the copy of last resort. Same call tank-snapshot.sh
			# makes when `written` is unreadable.
			log "  $TPATH: state file unreadable — treating as due"
			LAST_RUN=0
			;;
		esac
	fi

	AGE=$(( $(now) - LAST_RUN ))
	if [ "$FORCE" = 0 ] && [ "$AGE" -lt $((INTERVAL - SLACK)) ]; then
		log "  $TPATH: not due (last run ${AGE}s ago, interval ${INTERVAL}s)"
		SKIPPED="$SKIPPED $TPATH"
		continue
	fi

	if [ "$LAST_RUN" = 0 ]; then
		log "  $TPATH: due (never run) — backing up $MOUNT_ROOT/$TPATH"
	else
		log "  $TPATH: due (last run ${AGE}s ago) — backing up $MOUNT_ROOT/$TPATH"
	fi
	if ! check_mounted "$DSET" "$TPATH"; then
		FAILED="$FAILED $TPATH"
		continue
	fi

	# macOS VOLUME CRUFT. Every one of these is derived or disposable, and
	# several are unreadable even as root because SIP protects them — which is
	# how they got here: .Spotlight-V100 produced
	#   error: openfile for readdirnames failed: ... operation not permitted
	# on 2026-10-03, restic exited 3, and the run alerted. Left alone that is a
	# nightly false alarm forever, because Spotlight's index is never going to
	# become readable.
	#
	# Excluding beats classifying. An earlier fix whitelisted the
	# com.apple.FinderInfo errors as benign and left everything else alerting,
	# which was right in shape and too narrow in fact: FinderInfo is one member
	# of a family and the next member just re-opens the same wound. Not reading
	# them at all means there is no error to judge.
	#
	# Nothing here is user data. Spotlight's index and .fseventsd are
	# regenerable journals, .Trashes is already-deleted files, .TemporaryItems
	# is scratch, .DocumentRevisions-V100 is the Versions store for documents
	# this pool does not hold. .DS_Store is the one you already measured at
	# ~100x write amplification on a recordsize=1M dataset.
	set -- \
		--tag "$TPATH" --tag offsite \
		--pack-size "$PACK_SIZE" \
		-o s3.storage-class="$STORAGE_CLASS" \
		--exclude .DS_Store \
		--exclude .Spotlight-V100 \
		--exclude .fseventsd \
		--exclude .Trashes \
		--exclude .TemporaryItems \
		--exclude .DocumentRevisions-V100 \
		--exclude-caches \
		--one-file-system
	# Anything you want left out that is not platform cruft goes here, one
	# pattern per line. Kept separate from the list above because that one is
	# a fact about macOS and this one is your opinion.
	[ -f "$EXCLUDE_FILE" ] && set -- "$@" --exclude-file "$EXCLUDE_FILE"
	# A second tag naming the dataset, but only when it adds anything — for a
	# whole-dataset target the two strings are identical.
	[ "$DSET" != "$TPATH" ] && set -- "$@" --tag "$DSET"
	[ -n "$SKIP_UNCHANGED" ] && set -- "$@" "$SKIP_UNCHANGED"
	# The seed is attended and already a weekend; throttling it to 20 Mbit would
	# make it 80 hours instead of 54 for no benefit.
	[ "$SEED" = 0 ] && set -- "$@" --limit-upload "$LIMIT_UP"

	if [ "$DRY_RUN" = 1 ]; then
		log "  [dry-run] restic backup $* $MOUNT_ROOT/$TPATH"
		continue
	fi

	OUT=$("$RESTIC" backup "$@" "$MOUNT_ROOT/$TPATH" 2>&1)
	RC=$?

	# com.apple.FinderInfo is Finder metadata — icon positions and legacy
	# type/creator codes, the same class of junk as the .DS_Store we already
	# exclude. On OpenZFS-on-macOS restic cannot read it and emits one error
	# line PER FILE: 14076 files produced a wall of them on 2026-09-30. Collapse
	# it to a count, or the log blows its 1024 KB rotation trigger every run and
	# the lines that matter are impossible to find.
	XNOISE=$(printf '%s\n' "$OUT" | grep -c 'com.apple.FinderInfo')
	XREAL=$(printf '%s\n' "$OUT" | grep '^error:' | grep -vc 'com.apple.FinderInfo')
	# Drop the blank line restic emits AFTER each error, not just the error
	# itself. Filtering only the error text left 18 four-space lines in the log
	# on 2026-10-03 — the same wall of noise this exists to remove, minus the
	# words, and just as effective at pushing the real output off a screen.
	printf '%s\n' "$OUT" | grep -v 'com.apple.FinderInfo' |
		grep -v '^[[:space:]]*$' | sed 's/^/    /' >>"$LOG"
	[ "$XNOISE" -gt 0 ] &&
		log "    ($XNOISE com.apple.FinderInfo xattr errors suppressed — expected, see below)"

	case "$RC" in
	0) ;;
	3)
		# restic: "some source data could not be read (incomplete snapshot
		# created)". THE SNAPSHOT EXISTS. Treating that as a failure is wrong
		# in a way that compounds, and 2026-09-30 is the proof: the run was
		# marked failed, so the state file was never written, so every
		# subsequent night found my_media due, re-walked 491 GiB, hit the same
		# xattr errors and alerted again. By 2026-10-03 it had been doing that
		# nightly. A warning misread as a failure became an infinite retry
		# loop AND a nightly false alarm.
		#
		# So: record the snapshot and write the state either way. What the
		# errors WERE decides whether anyone is told.
		if [ "$XREAL" -gt 0 ]; then
			alert "$TPATH: $XREAL source file(s) could not be read." \
				"The snapshot was still created and is usable, but it is
incomplete. These are NOT the expected Finder xattr errors:

$(printf '%s\n' "$OUT" | grep '^error:' | grep -v 'com.apple.FinderInfo' | head -10)"
			WARNED="$WARNED $TPATH"
		else
			# Only the xattr noise. File CONTENTS all read fine — the
			# 2026-09-30 run reported 14076 files and 491.539 GiB processed
			# with 0 unread. Nothing is missing that we would have kept.
			log "  $TPATH: rc=3 from Finder xattrs only — snapshot is complete in content"
		fi
		;;
	11)
		alert "$TPATH: the repository is locked by another run." \
			"If no run is active, clear it by hand:
  sudo $RESTIC unlock
Do NOT script that — an automatic unlock would break the one thing stopping
two runs from writing at once."
		FAILED="$FAILED $TPATH"
		continue
		;;
	*)
		case "$OUT" in
		*"repository is already locked"*)
			alert "$TPATH: the repository is locked by another run." \
				"Clear it by hand with: sudo $RESTIC unlock"
			;;
		*) alert "$TPATH: restic backup FAILED (rc=$RC)" "$(printf '%s' "$OUT" | tail -20)" ;;
		esac
		FAILED="$FAILED $TPATH"
		continue
		;;
	esac

	# "snapshot abc12345 saved". Absent when --skip-if-unchanged decided nothing
	# changed, which is a success, not a failure.
	NEW=$(printf '%s\n' "$OUT" | awk '/snapshot [0-9a-f]+ saved/ { print $2; exit }')
	if [ -z "$NEW" ]; then
		log "  $TPATH: nothing changed — no snapshot recorded"
		echo "$(now) $PARENT" >"$STATE"
		RAN="$RAN $TPATH"
		continue
	fi

	log "  $TPATH: snapshot $NEW saved"
	echo "$(now) $NEW" >"$STATE"
	RAN="$RAN $TPATH"

done <"$TABLE"
rm -f "$TABLE"

# --------------------------------------------- storage-class invariant

# restic must read config, keys/, index/, snapshots/ and locks/ on EVERY run,
# and the tree packs in data/ on nearly every command. All of them must be in
# Standard. See DESIGN 5 for how they get there.
#
# The failure a wrong class produces is the worst shape available: it arrives
# WEEKS after the cause, with nothing in between to connect the two. A
# lifecycle rule someone adds, a console click, a restic upgrade that changes
# what the storage-class option touches. On 2026-10-10 it was this script's own
# lifecycle rule, and this check did not catch it because it looked only at
# the prefixes outside data/ — the trees were assumed safe because nothing said
# otherwise. Now it looks at them by id.
#
# This began as a diary entry — "~8 October: confirm data/ actually moved" —
# which answers the question once, on one day, if someone remembers. As an
# invariant it answers it every night, including the night in 2029 after
# someone tidies up the bucket.
#
# Returns 0 healthy, 1 violated, 2 could not check.
check_storage_classes() {
	[ -n "$BUCKET" ] || {
		log "  storage-class check: no OFFSITE_BUCKET in $CONF_DIR/env — SKIPPED"
		return 2
	}
	[ -x "$AWS_CLI" ] || {
		log "  storage-class check: $AWS_CLI not found — SKIPPED"
		return 2
	}
	[ -x "$JQ" ] || {
		log "  storage-class check: $JQ not found — SKIPPED"
		return 2
	}

	csc_bad=''
	for csc_pfx in config keys/ index/ snapshots/ locks/; do
		# The `grep -v None` is load-bearing and cost a false alarm to find.
		# When a prefix matches NO objects, list-objects-v2 leaves Contents
		# out of the response entirely, the JMESPath expression evaluates to
		# null, and --output text renders that as the literal string "None".
		# Without this filter an EMPTY prefix reads as a violation — and
		# locks/ is empty almost always, since restic removes its own locks
		# and this script calls `restic unlock` before anything else.
		#
		# So the very first real run alerted "the repository will stop
		# opening" about a perfectly healthy bucket. Found because the test
		# stub returned "" where AWS returns "None": the fake was kinder than
		# reality, so the suite passed on code that could not work.
		csc_out=$("$AWS_CLI" s3api list-objects-v2 --bucket "$BUCKET" \
			--prefix "$csc_pfx" \
			--query 'Contents[?StorageClass!=`STANDARD`].[Key,StorageClass]' \
			--output text 2>/dev/null | grep -v '^None$' | sed '/^[[:space:]]*$/d')
		[ -n "$csc_out" ] && csc_bad="$csc_bad$csc_out
"
	done

	if [ -n "$csc_bad" ]; then
		alert "restic METADATA has left Standard storage — the repository will stop opening." \
			"No lifecycle rule may transition anything in this bucket — restic
picks the storage class itself (DESIGN 5). Something has moved these, and
restic cannot read an archived object at all.

$(printf '%s' "$csc_bad" | head -10)

Remove the rule, then restore these objects to Standard. Until both are done
no backup can run and no restore can start.

  aws s3api get-bucket-lifecycle-configuration --bucket $BUCKET"
		return 1
	fi

	# Tree packs, by id. Which packs are trees is only in restic's index, so
	# this reads it. An index that cannot be read means this cannot answer,
	# which is "skipped", not "ok".
	csc_trees=$(mktemp /tmp/tank-offsite-trees.XXXXXX) || return 2
	if ! tree_packs >"$csc_trees" || [ ! -s "$csc_trees" ]; then
		rm -f "$csc_trees"
		log "  storage-class check: could not read restic's index to find tree packs — SKIPPED"
		return 2
	fi
	csc_ntrees=$(wc -l <"$csc_trees" | tr -d ' ')
	if ! csc_objs=$(list_data_classes 2>/dev/null); then
		rm -f "$csc_trees"
		log "  storage-class check: listing data/ failed — SKIPPED"
		return 2
	fi
	csc_plan=$(printf '%s\n' "$csc_objs" | misfiled_packs "$csc_trees")
	rm -f "$csc_trees"
	csc_cold=$(printf '%s\n' "$csc_plan" | grep -c '^tree')
	csc_warm=$(printf '%s\n' "$csc_plan" | grep -c '^content')

	if [ "$csc_cold" -gt 0 ]; then
		alert "$csc_cold restic TREE pack(s) are out of Standard storage — check, prune and restore will fail." \
			"Tree packs hold every snapshot's directory structure and restic reads
them on nearly every command. They live in data/ next to the content packs,
so a lifecycle rule on data/ catches them too.

$(printf '%s\n' "$csc_plan" | grep '^tree' | cut -f2 | head -10)

Make sure no lifecycle rule transitions data/, then thaw them and move them
back (re-run after ~12 h until it says done):
  pass show nas/offsite-prune-aws | sudo $0 --fix-classes"
		return 1
	fi

	# Content left in Standard is money, not breakage, so it is logged rather
	# than alerted. Expected to be 0: restic uploads content straight to
	# $STORAGE_CLASS. A number that grows night after night means the option
	# is not reaching restic.
	csc_note=
	[ "$csc_warm" -gt 0 ] &&
		csc_note="; $csc_warm content pack(s) still in STANDARD — --fix-classes moves them"
	log "  storage classes OK: metadata and $csc_ntrees tree pack(s) STANDARD$csc_note"
	return 0
}

SCLASS=ok
check_storage_classes
case $? in
1) SCLASS=VIOLATED; FAILED="$FAILED storage-class" ;;
2) SCLASS=skipped ;;
esac

# --------------------------------------------------------------------- check

# Metadata-only: index, snapshots, and every tree pack — which is why the tree
# packs must stay in Standard (DESIGN 5). It never reads content, so Deep
# Archive does not bother it. `check --read-data`, which re-verifies every
# chunk, would need the whole archive pulled out of Glacier and is not
# available to us at all.
if [ -n "$RAN" ] && [ "$DRY_RUN" = 0 ]; then
	# NOT `restic check | sed`: a pipeline's status is the LAST command's, and
	# sed always succeeds, so a failing check would be logged as clean. Same
	# bug bootstrap-offsite.sh had on `restic init`.
	# --retry-lock, because the default is NO retries and that bit on
	# 2026-10-03: check wants an EXCLUSIVE lock, while backup and restore take
	# shared ones. A shared lock left behind by one of this run's own restore
	# calls is invisible to every later backup and restore and stops check
	# dead — "repo already locked, waiting up to 0s for the lock".
	CHECK_OUT=$("$RESTIC" check --retry-lock 5m 2>&1)
	CHECK_RC=$?
	printf '%s\n' "$CHECK_OUT" | grep -v '^[[:space:]]*$' | sed 's/^/    /' >>"$LOG"
	if [ "$CHECK_RC" = 0 ]; then
		log "  restic check: clean"
	else
		case "$CHECK_OUT" in
		*"already locked"*)
			# Say what this is. The old wording here was "the repository's own
			# bookkeeping does not agree", which describes CORRUPTION — the
			# single most alarming thing this daemon can report — for what is
			# actually a leftover lock file. The backup itself succeeded and
			# nothing about the data is in question.
			alert "restic check could not run: the repository is still locked." \
				"This is lock contention, NOT a corruption finding. The backup
succeeded and the data is not in question; check simply never ran.

If no restic process is alive, clear the stale lock by hand:
  sudo $RESTIC unlock
Then re-run. Deliberately not scripted — an automatic unlock would defeat
the thing that stops two runs writing at once."
			;;
		*"not valid for the object's storage class"*)
			# 2026-10-10: tree packs had gone to Deep Archive. The generic
			# wording below says "bookkeeping does not agree", which reads as
			# corruption. Nothing is corrupt; restic is locked out of it.
			alert "restic check could not read tree packs: they are in Deep Archive." \
				"This is NOT corruption. The backup succeeded; check needs the
snapshots' directory structure and S3 will not serve it from Glacier. The
storage-class check in this run names the packs and the fix:
  pass show nas/offsite-prune-aws | sudo $0 --fix-classes"
			;;
		*)
			alert "restic check reported problems after a successful backup." \
				"The upload worked; the repository's own bookkeeping does not
agree. See $LOG."
			;;
		esac
		FAILED="$FAILED check"
	fi
fi

# ----------------------------------------------------------------- epilogue

SUMMARY="ran:[${RAN:-none}] warned:[${WARNED:-none}] failed:[${FAILED:-none}] not-due:[${SKIPPED:-none}] storage-class:[$SCLASS]"
log "  $SUMMARY"
echo "$(date '+%Y-%m-%d %H:%M:%S') $SUMMARY" >"$LAST"

# WARNED exits nonzero too: the snapshot was made and the state written, so
# there is no retry loop, but an incomplete backup must not read as a clean one.
if [ -n "$FAILED" ] || [ -n "$WARNED" ]; then
	log "=== run end: FAILURES ==="
	exit 2
fi

# Heartbeat on its own clock — see DESIGN 6. Not tied to a backup having
# happened, because with --skip-if-unchanged the quiet months are the healthy
# ones and a heartbeat that goes silent when all is well inverts the signal.
if [ "$DRY_RUN" = 0 ]; then
	HB_AGE=$((HEARTBEAT_DAYS * 86400 + 1))
	if [ -f "$HEARTBEAT" ]; then
		HB_MTIME=$(stat -f %m "$HEARTBEAT" 2>/dev/null || echo 0)
		HB_AGE=$(( $(now) - HB_MTIME ))
	fi
	if [ "$HB_AGE" -gt $((HEARTBEAT_DAYS * 86400)) ]; then
		notify "tank-offsite: ${HEARTBEAT_DAYS}-day summary on $(hostname -s)" \
			"$SUMMARY

$("$RESTIC" snapshots --group-by paths 2>&1 | tail -20)"
		touch "$HEARTBEAT"
	fi
fi

log "=== run end: ok ==="
exit 0
