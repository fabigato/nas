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
# 5. THE READ-BACK CHECK EXISTS BECAUSE `restic backup` EXITING 0 PROVES THE
#    UPLOAD, NOT THE ARCHIVE.
#
# After a run that sent something, this restores a few of the files that
# CHANGED THIS RUN and compares checksums against the source. "Changed this
# run" is load-bearing: those packs were written minutes ago, so the lifecycle
# rule has not moved them to Deep Archive yet and reading them back is instant,
# free, and needs no Glacier restore. An unchanged file's chunks live in old,
# cold packs and could not be read without a 12-hour round trip.
#
# It is a spot check, not a verification. `restic check --read-data` — which
# re-downloads and re-verifies every chunk — cannot be run against Deep Archive
# at all. That gap is real and is why the quarterly restore test exists.
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
#   sudo sh tank-offsite.sh --drop <id>     # forget one snapshot you know is
#                                           # junk, then reclaim it
#
# Exit codes:
#   0  ran, or correctly had nothing to do
#   1  refused to start (pool, mount, config, tooling)
#   2  a backup or check failed, or a snapshot is incomplete — READ THE LOG
#   3  deferred (a scrub is running, or another run still has the lock)

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

# How many changed files the read-back check pulls, and the total it will pull.
# Bounded because this runs unattended: a monthly run that decides to re-download
# 40 GB to "verify" it has become the problem rather than the check.
VERIFY_FILES=${TANK_OFFSITE_VERIFY_FILES:-3}
VERIFY_MAX_BYTES=${TANK_OFFSITE_VERIFY_MAX_BYTES:-536870912}

# A run holds this for its whole duration so the next nightly fire defers
# instead of colliding. /var/run is cleared at boot, which disposes of a lock
# orphaned by a panic for free.
LOCKDIR=${TANK_OFFSITE_LOCKDIR:-/var/run/tank-offsite.lock}

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

# --------------------------------------------------------------- list / drop

if [ "$MODE" = list ]; then
	"$RESTIC" snapshots --group-by paths 2>&1 | tee -a "$LOG"
	exit $?
fi

if [ "$MODE" = drop ]; then
	log "  dropping snapshot $DROP_ID"
	echo "About to forget snapshot $DROP_ID and reclaim its unreferenced data."
	echo "This is not reversible. Snapshots currently in the repository:"
	echo
	"$RESTIC" snapshots --group-by paths 2>&1 | sed 's/^/  /'
	echo
	printf 'Type the snapshot id again to confirm: '
	read -r confirm
	[ "$confirm" = "$DROP_ID" ] || die "confirmation did not match — nothing done"
	if [ "$DRY_RUN" = 1 ]; then
		echo "[dry-run] restic forget $DROP_ID && restic prune --max-repack-size 0"
		exit 0
	fi
	"$RESTIC" forget "$DROP_ID" 2>&1 | tee -a "$LOG" || die "forget failed" 2
	# --max-repack-size 0 keeps prune from repacking partially-used packs, which
	# would mean downloading them out of Deep Archive. Delete-only reclaim.
	"$RESTIC" prune --max-repack-size 0 2>&1 | tee -a "$LOG" || die "prune failed" 2
	log "  dropped $DROP_ID"
	exit 0
fi

# ------------------------------------------------------------------- backup

# Restore a handful of the files this run changed and checksum them against the
# source. See DESIGN 5 for why only changed files, and why this is a spot check.
# $1 = dataset, $2 = parent snapshot id or empty, $3 = new snapshot id
read_back_check() {
	rb_ds=$1   # relative path, e.g. my_media or media/concerts
	rb_parent=$2
	rb_new=$3

	[ -n "$rb_new" ] || { log "  read-back: no new snapshot id — skipped"; return 0; }

	if [ -z "$rb_parent" ]; then
		# First run for this dataset: every chunk in the snapshot was uploaded
		# minutes ago, so any file in it is warm. Take the first few.
		#
		# THE LIST COMES FROM THE SNAPSHOT, NOT FROM `find` ON THE SOURCE.
		# An earlier version walked the source tree, which also yields the
		# files we deliberately EXCLUDED — so it would pick a .DS_Store,
		# correctly fail to restore something that was never backed up, and
		# report MISMATCH on a perfectly good repository. On this pool that is
		# not a corner case: my_media is full of .DS_Store, so the FIRST real
		# run would have alerted "treat the repository as suspect". An alarm
		# that cries wolf on day one trains you to ignore the channel, which
		# costs more than having no check at all. Caught by smoke-local.sh.
		#
		# The snapshot is the only authority on what was actually backed up.
		rb_cands=$("$RESTIC" ls "$rb_new" 2>/dev/null | grep '^/' | head -40)
	else
		# `restic diff` marks added paths with + and modified ones with M.
		# Those are the chunks written minutes ago, still in Standard, which is
		# the entire reason this check is free. sed rather than awk on $1 so a
		# path containing runs of spaces survives intact.
		rb_cands=$("$RESTIC" diff "$rb_parent" "$rb_new" 2>/dev/null |
			sed -n 's/^[+M][[:space:]]*//p' | head -40)
	fi

	if [ -z "$rb_cands" ]; then
		log "  read-back: nothing changed to check"
		return 0
	fi

	rb_tmp=$(mktemp -d /tmp/tank-offsite-verify.XXXXXX) || return 0
	rb_done=0
	rb_bytes=0
	rb_fail=0

	# Fed by REDIRECTION, not by a pipe. `cmd | while read` runs the loop in a
	# subshell, so rb_fail and rb_bytes would be discarded at `done` and this
	# function would always return success. Redirection keeps it in this shell.
	printf '%s\n' "$rb_cands" >"$rb_tmp/.cands"
	while IFS= read -r rb_path; do
		[ -f "$rb_path" ] || continue
		rb_size=$(stat -f %z "$rb_path" 2>/dev/null) || continue
		[ "$rb_size" -gt 0 ] || continue
		rb_bytes=$((rb_bytes + rb_size))
		[ "$rb_bytes" -le "$VERIFY_MAX_BYTES" ] || break

		if ! "$RESTIC" restore "$rb_new" --target "$rb_tmp" \
			--include "$rb_path" >/dev/null 2>&1; then
			log "  read-back: FAILED to restore $rb_path"
			rb_fail=1
			continue
		fi
		rb_src=$(shasum -a 256 "$rb_path" 2>/dev/null | awk '{print $1}')
		rb_got=$(shasum -a 256 "$rb_tmp$rb_path" 2>/dev/null | awk '{print $1}')
		if [ -n "$rb_src" ] && [ "$rb_src" = "$rb_got" ]; then
			log "  read-back: OK $rb_path"
		else
			log "  read-back: MISMATCH $rb_path (src=$rb_src got=${rb_got:-none})"
			rb_fail=1
		fi

		rb_done=$((rb_done + 1))
		[ "$rb_done" -lt "$VERIFY_FILES" ] || break
	done <"$rb_tmp/.cands"

	log "  read-back: checked $rb_done file(s)"
	rm -rf "$rb_tmp"
	return $rb_fail
}

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

	log "  $TPATH: due (last run ${AGE}s ago) — backing up $MOUNT_ROOT/$TPATH"
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
	if read_back_check "$TPATH" "$PARENT" "$NEW"; then
		log "  $TPATH: read-back check passed"
	else
		alert "$TPATH: READ-BACK CHECK FAILED on snapshot $NEW." \
			"The upload reported success but a file restored from it does not
match the source. Treat the repository as suspect and run the full restore
test before relying on it. Details in $LOG."
		FAILED="$FAILED $TPATH"
		continue
	fi

	echo "$(now) $NEW" >"$STATE"
	RAN="$RAN $TPATH"

done <"$TABLE"
rm -f "$TABLE"

# --------------------------------------------------------------------- check

# Metadata-only. This validates that the bookkeeping is self-consistent and
# reads nothing out of data/, so it costs nothing and works fine against Deep
# Archive. `check --read-data`, which re-verifies every chunk, would need the
# whole archive pulled out of Glacier and is not available to us at all.
if [ -n "$RAN" ] && [ "$DRY_RUN" = 0 ]; then
	# NOT `restic check | sed`: a pipeline's status is the LAST command's, and
	# sed always succeeds, so a failing check would be logged as clean. Same
	# bug bootstrap-offsite.sh had on `restic init`.
	CHECK_OUT=$("$RESTIC" check 2>&1)
	CHECK_RC=$?
	printf '%s\n' "$CHECK_OUT" | sed 's/^/    /' >>"$LOG"
	if [ "$CHECK_RC" = 0 ]; then
		log "  restic check: clean"
	else
		alert "restic check reported problems after a successful backup." \
			"The upload worked; the repository's own bookkeeping does not agree.
See $LOG."
		FAILED="$FAILED check"
	fi
fi

# ----------------------------------------------------------------- epilogue

SUMMARY="ran:[${RAN:-none}] warned:[${WARNED:-none}] failed:[${FAILED:-none}] not-due:[${SKIPPED:-none}]"
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
