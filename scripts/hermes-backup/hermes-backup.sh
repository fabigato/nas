#!/bin/sh
#
# hermes-backup.sh — copy the Hermes agents' personalities out of ~/.hermes into
# /Volumes/tank/documents/hermes, where local.tank-offsite picks it up.
#
# WHAT THIS IS FOR
# ~/.hermes is ~2.9 GB, but almost all of that is the code checkout, a bundled
# node and caches — all reinstallable. What cannot be reinstalled is ~60 MB: the
# persona, its memories, its skills, its conversation history and its config.
# This copies exactly that, consistently, once a day, onto `tank`. From there
# tank-snapshot keeps history (documents: 7 daily, 4 weekly, 6 monthly) and the
# `documents` target in /etc/tank-offsite/targets sends it off-site with the
# rest of the dataset. It belongs in documents, not media: it is irreplaceable
# and it changes daily, which is exactly what that dataset is for.
#
# --- DESIGN ---------------------------------------------------------------
#
# 1. RUNS AS ROOT, BUT TOUCHES ~/.hermes ONLY AS THE OWNER.
#
# Root because the notification webhook lives in zed.rc, which is 0600 root —
# the same single place every other daemon here reads it from. But every read
# of ~/.hermes and every write under the destination goes through as_user().
# That is not tidiness: opening a WAL-mode SQLite database creates its -shm and
# -wal files if they are missing. Done as root, Hermes would find a root-owned
# state.db-shm next to its own database, fail to open it, and break. Copies come
# out owned by fabigato for free.
#
# 2. DATABASES GO THROUGH `sqlite3 .backup`, NOT cp.
#
# Hermes runs all day and writes state.db in WAL mode. A file copy taken
# mid-write is a database with half a transaction in it, or one that is missing
# whatever still sits in the -wal file. The online backup API takes a consistent
# snapshot under SQLite's own locking. Every copy is then integrity-checked, and
# a copy that fails the check fails the run.
#
# 3. IT REFUSES TO OVERWRITE A GOOD BACKUP WITH A BLANK AGENT.
#
# The same trap as tank-offsite's design 2. If ~/.hermes is wiped, reinstalled
# fresh, or Hermes is reset, the next nightly run would faithfully copy a blank
# personality over the real one. Snapshots would still hold the old one, but
# only for as long as their retention, and every night of not noticing pushes
# another good day out. So: SOUL.md and
# memories/ must exist, and state.db must not have shrunk below
# SHRINK_LIMIT_PCT of the previous copy. Either refuses the run and alerts.
# If the shrink is genuine (you pruned history on purpose), run once by hand
# with --force.
#
# 4. A WHOLE-DIRECTORY SWAP, NOT AN IN-PLACE SYNC.
#
# The new copy is built in .incoming/ and only replaces current/ once every
# step has succeeded. A run that dies halfway leaves yesterday's complete copy
# where it was rather than a mix of two days. The off-site target is the parent
# directory, and this runs at 01:00, before tank-offsite at 01:30, so restic
# sees a finished swap.
#
# 5. AN ALLOW-LIST, NOT AN EXCLUDE-LIST.
#
# New cache directories appear with every Hermes release. Listing what to KEEP
# means a new cache is ignored by default; listing what to DROP would mean every
# release quietly grows the backup. The cost is that a new piece of state is
# also ignored by default — MANIFEST records the top-level entries of ~/.hermes
# that were NOT copied, so a new one is visible there.
#
# 6. A NIGHT WITH NO CHANGES WRITES NOTHING.
#
# tank/documents keeps daily snapshots, and tank-snapshot skips a snapshot
# when nothing was written. A naive nightly full copy would defeat both: every
# night ~20 MB of new blocks pinned by a snapshot, and "keep 7 daily" filled
# with identical states. So unchanged directory files are hard-linked to the
# previous copy (rsync --link-dest), and when the whole new copy matches the
# old one the swap is skipped altogether. That works because `sqlite3 .backup`
# of an unchanged database is byte-identical (checked 2026-10-04).
#
# 7. EVERY PROFILE IS ITS OWN AGENT, BACKED UP ON ITS OWN.
#
# Hermes profiles (~/.hermes/profiles/<name>) are separate agents with the same
# layout as ~/.hermes. Each gets the treatment above, into a tree that mirrors
# the source: the default agent stays at hermes/current, a profile goes to
# hermes/profiles/<name>/current. Profiles are found, not listed, so a new one
# is backed up without touching this script. Each agent runs in its own
# subshell: one refusing or failing does not stop the others, and the run
# reports every problem in one alert and exits with the worst code. A profile
# that is still blank and has never been copied is skipped quietly — there is
# nothing to protect yet. A deleted profile's last copy is left where it is.
#
# Exit codes:  0 ok · 1 refused (tank/documents not mounted, an agent looks blank
#              or shrunk) · 2 an operation failed

set -u
umask 077

OWNER=${HERMES_BACKUP_OWNER:-fabigato}
SRC=${HERMES_BACKUP_SRC:-/Users/$OWNER/.hermes}
DATASET=${HERMES_BACKUP_DATASET:-tank/documents}
DEST=${HERMES_BACKUP_DEST:-/Volumes/tank/documents/hermes}
LOG=${HERMES_BACKUP_LOG:-/var/log/hermes-backup.log}
LAST=${HERMES_BACKUP_LAST:-/var/log/hermes-backup.last}
ZEDRC=${HERMES_BACKUP_ZEDRC:-/etc/zfs/zed.d/zed.rc}
ZFS=/usr/local/zfs/bin/zfs
SQLITE=/usr/bin/sqlite3
SHRINK_LIMIT_PCT=50
NOTIFY_MAX_CHARS=1500

# What makes the agent itself. Paths relative to $SRC. Missing entries are
# skipped silently — most of the small ones only appear once a feature is used.
FILES="SOUL.md config.yaml .env channel_directory.json .hermes_history profile.yaml"
DIRS="memories skills sessions cron platforms pairing hooks plans"
DBS="state.db kanban.db projects.db cron/executions.db"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Already the owner when run by hand with the env overrides to test it.
as_user() {
	if [ "$(id -un)" = "$OWNER" ]; then "$@"; else /usr/bin/sudo -n -u "$OWNER" "$@"; fi
}

# Copy of tank-snapshot.sh's notify(); see that file for why it is a copy and
# why it checks the HTTP status itself rather than using zed_notify().
# $1 = subject, $2 = body.
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

# $1 = exit code, $2 = reason (one line per problem). Logs, alerts, writes
# .last, exits.
finish() {
	rc=$1
	if [ "$rc" -ne 0 ]; then
		log "$2"
		/usr/bin/logger -t hermes-backup -p daemon.err "$(echo "$2" | tr '\n' ' ')"
		notify "hermes-backup on $(hostname -s)" "$2"
	fi
	echo "$(date '+%Y-%m-%d %H:%M:%S') exit $rc $(echo "${2:-ok}" | tr '\n' ' ')" >"$LAST"
	log "--- done (exit $rc) ---"
	exit "$rc"
}

# Inside backup_agent's subshell: record why this agent failed, clean up, and
# leave the subshell (not the script). $1 = exit code, $2 = reason.
fail() {
	echo "[$NAME] $2" >>"$PROBLEMS"
	[ -n "${INCOMING:-}" ] && as_user rm -rf "$INCOMING"
	exit "$1"
}

# umask 077 is for the copy, which holds .env. The logs hold no secrets and are
# 644 like the other daemons', so `cat hermes-backup.last` works without sudo.
touch "$LOG" "$LAST" && chmod 644 "$LOG" "$LAST"

log "--- hermes-backup start (force=$FORCE) ---"

# --- guards ---------------------------------------------------------------

# An unmounted dataset leaves /Volumes/tank/documents as a plain directory on the
# boot disk. Writing there would succeed and back up nothing anyone can find.
mounted=$("$ZFS" get -H -o value mounted "$DATASET" 2>/dev/null)
[ "$mounted" = "yes" ] || finish 1 "refused: $DATASET is not mounted (got '${mounted:-nothing}')"

as_user mkdir -p "$DEST" || finish 2 "could not create $DEST"

# One line per agent that refused or failed; read back after the loop.
PROBLEMS=$(mktemp -t hermes-backup) || finish 2 "mktemp failed"
trap 'rm -f "$PROBLEMS"' EXIT

# Both default to the main install; the code checkout is shared by all profiles.
commit=$(as_user git -C "$SRC/hermes-agent" rev-parse HEAD 2>/dev/null)
version=$(as_user "$SRC/hermes-agent/venv/bin/python" -m hermes_cli.main --version 2>/dev/null | head -1)

# $1 = the agent's home, $2 = where its copies go, $3 = its name. Run in a
# subshell: fail() exits only this agent. See design 7.
backup_agent() {
	AGENT=$1
	OUT=$2
	NAME=$3
	INCOMING=

	if ! { [ -f "$AGENT/SOUL.md" ] && [ -d "$AGENT/memories" ] && [ -f "$AGENT/state.db" ]; }; then
		if [ "$NAME" != default ] && [ ! -d "$OUT/current" ]; then
			log "  [$NAME] no SOUL.md, memories/ or state.db yet and never copied; skipped"
			exit 0
		fi
		fail 1 "refused: $AGENT has no SOUL.md, memories/ or state.db — a blank or missing agent, not backing it up over the last good copy"
	fi

	as_user mkdir -p "$OUT" || fail 2 "could not create $OUT"
	INCOMING=$OUT/.incoming
	as_user rm -rf "$INCOMING"
	as_user mkdir -p "$INCOMING" || fail 2 "could not create $INCOMING"

	# --- copy ---

	for f in $FILES; do
		[ -e "$AGENT/$f" ] || continue
		as_user cp -p "$AGENT/$f" "$INCOMING/$f" || fail 2 "cp $f failed"
	done

	for d in $DIRS; do
		[ -d "$AGENT/$d" ] || continue
		# Unchanged files become hard links into current/, so they cost no new
		# blocks in the documents snapshots. See design 6.
		set --
		[ -d "$OUT/current/$d" ] && set -- --link-dest="$OUT/current/$d/"
		# skills/.hub is the hub's index cache (~40 MB), re-downloaded on demand.
		# cron/ticker_* are the scheduler's liveness stamps, rewritten every
		# minute; copying them would make every run look like a change.
		as_user rsync -a "$@" --exclude '*.lock' --exclude '.hub/' --exclude 'ticker_*' \
			"$AGENT/$d/" "$INCOMING/$d/" || fail 2 "rsync $d failed"
	done

	for db in $DBS; do
		[ -f "$AGENT/$db" ] || continue
		as_user mkdir -p "$INCOMING/$(dirname "$db")"
		# rsync above copied cron/ including a live executions.db; replace it.
		as_user rm -f "$INCOMING/$db"
		as_user "$SQLITE" "$AGENT/$db" ".timeout 30000" ".backup '$INCOMING/$db'" 2>>"$LOG" ||
			fail 2 "sqlite .backup of $db failed"
		check=$(as_user "$SQLITE" "$INCOMING/$db" "PRAGMA integrity_check;" 2>&1)
		[ "$check" = "ok" ] || fail 2 "integrity_check of the copied $db failed: $check"
		# The copy is still in WAL mode, so opening it to check it leaves -shm and
		# an empty -wal behind. Empty means nothing of the copy lives there.
		if [ ! -s "$INCOMING/$db-wal" ]; then
			as_user rm -f "$INCOMING/$db-wal" "$INCOMING/$db-shm"
		fi
	done

	# --- shrink guard ---

	if [ -f "$OUT/current/state.db" ] && [ "$FORCE" -eq 0 ]; then
		old=$(stat -f %z "$OUT/current/state.db")
		new=$(stat -f %z "$INCOMING/state.db")
		if [ "$old" -gt 0 ] && [ $((new * 100 / old)) -lt "$SHRINK_LIMIT_PCT" ]; then
			fail 1 "refused: state.db shrank from $old to $new bytes (below ${SHRINK_LIMIT_PCT}%). Was the agent reset? Kept the previous copy. If intended: sudo /usr/local/sbin/hermes-backup.sh --force"
		fi
	fi

	# --- unchanged? ---

	# Leave current/ untouched when nothing changed, so tank-snapshot sees no
	# writes and skips the snapshot. See design 6.
	if [ -d "$OUT/current" ] &&
		as_user diff -rq -x MANIFEST "$INCOMING" "$OUT/current" >/dev/null 2>&1; then
		as_user rm -rf "$INCOMING"
		log "  [$NAME] unchanged since the last copy; left $OUT/current as it was"
		exit 0
	fi

	# --- manifest ---

	copied=$(cd "$INCOMING" && ls -A | tr '\n' ' ')
	# The default agent's profiles/ is not skipped: each profile has its own copy.
	skipped=$(cd "$AGENT" && for e in $(ls -A); do
		[ "$NAME" = default ] && [ "$e" = profiles ] && continue
		[ -e "$INCOMING/$e" ] || printf '%s ' "$e"
	done)
	as_user sh -c "cat >'$INCOMING/MANIFEST'" <<EOF
taken:          $(date '+%Y-%m-%d %H:%M:%S %z')
host:           $(hostname -s)
agent:          $NAME
source:         $AGENT
hermes:         ${version:-unknown}
hermes-agent:   ${commit:-unknown}

Restore: reinstall Hermes, check out the commit above in $SRC/hermes-agent
(so state.db's schema matches), stop Hermes, copy everything here into
$AGENT, start Hermes.

copied:  $copied
not copied (reinstallable, caches, or new — check this list after upgrades):
         $skipped
EOF

	# --- swap ---

	as_user rm -rf "$OUT/.previous"
	if [ -d "$OUT/current" ]; then
		as_user mv "$OUT/current" "$OUT/.previous" || fail 2 "could not move current aside"
	fi
	as_user mv "$INCOMING" "$OUT/current" || {
		as_user mv "$OUT/.previous" "$OUT/current"
		fail 2 "could not move .incoming into place; restored the previous copy"
	}
	INCOMING=
	as_user rm -rf "$OUT/.previous"

	log "  [$NAME] copied to $OUT/current ($(du -sh "$OUT/current" | cut -f1)), hermes-agent ${commit:-unknown}"
	exit 0
}

# --- run -------------------------------------------------------------------

worst=0
note() { [ "$1" -gt "$worst" ] && worst=$1; }

(backup_agent "$SRC" "$DEST" default)
note $?

for p in "$SRC"/profiles/*/; do
	[ -d "$p" ] || continue
	name=$(basename "$p")
	(backup_agent "${p%/}" "$DEST/profiles/$name" "$name")
	note $?
done

# A profile deleted from Hermes keeps its last copy; say so once a night.
for c in "$DEST"/profiles/*/; do
	[ -d "$c" ] || continue
	name=$(basename "$c")
	[ -d "$SRC/profiles/$name" ] || log "  [$name] no longer in $SRC/profiles; its last copy stays in ${c%/}"
done

[ "$worst" -eq 0 ] && finish 0
[ -s "$PROBLEMS" ] || echo "an agent's backup exited $worst without saying why; see $LOG" >>"$PROBLEMS"
finish "$worst" "$(cat "$PROBLEMS")"
