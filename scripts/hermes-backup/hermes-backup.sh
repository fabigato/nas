#!/bin/sh
#
# hermes-backup.sh — copy the Hermes agent's personality out of ~/.hermes into
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
# Exit codes:  0 ok · 1 refused (tank/documents not mounted, source looks blank or
#              shrunk) · 2 an operation failed

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
FILES="SOUL.md config.yaml .env channel_directory.json .hermes_history"
DIRS="memories skills sessions cron platforms pairing hooks"
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

# $1 = exit code, $2 = one-line reason. Logs, alerts, writes .last, exits.
finish() {
	rc=$1
	if [ "$rc" -ne 0 ]; then
		log "$2"
		/usr/bin/logger -t hermes-backup -p daemon.err "$2"
		notify "hermes-backup on $(hostname -s)" "$2"
		[ -n "${INCOMING:-}" ] && as_user rm -rf "$INCOMING"
	fi
	echo "$(date '+%Y-%m-%d %H:%M:%S') exit $rc ${2:-ok}" >"$LAST"
	log "--- done (exit $rc) ---"
	exit "$rc"
}

log "--- hermes-backup start (force=$FORCE) ---"

# --- guards ---------------------------------------------------------------

# An unmounted dataset leaves /Volumes/tank/documents as a plain directory on the
# boot disk. Writing there would succeed and back up nothing anyone can find.
mounted=$("$ZFS" get -H -o value mounted "$DATASET" 2>/dev/null)
[ "$mounted" = "yes" ] || finish 1 "refused: $DATASET is not mounted (got '${mounted:-nothing}')"

[ -f "$SRC/SOUL.md" ] && [ -d "$SRC/memories" ] && [ -f "$SRC/state.db" ] ||
	finish 1 "refused: $SRC has no SOUL.md, memories/ or state.db — a blank or missing agent, not backing it up over the last good copy"

as_user mkdir -p "$DEST" || finish 2 "could not create $DEST"
INCOMING=$DEST/.incoming
as_user rm -rf "$INCOMING"
as_user mkdir -p "$INCOMING" || finish 2 "could not create $INCOMING"

# --- copy -----------------------------------------------------------------

for f in $FILES; do
	[ -e "$SRC/$f" ] || continue
	as_user cp -p "$SRC/$f" "$INCOMING/$f" || finish 2 "cp $f failed"
done

for d in $DIRS; do
	[ -d "$SRC/$d" ] || continue
	# Unchanged files become hard links into current/, so they cost no new
	# blocks in the documents snapshots. See design 6.
	set --
	[ -d "$DEST/current/$d" ] && set -- --link-dest="$DEST/current/$d/"
	# skills/.hub is the hub's index cache (~40 MB), re-downloaded on demand.
	# cron/ticker_* are the scheduler's liveness stamps, rewritten every
	# minute; copying them would make every run look like a change.
	as_user rsync -a "$@" --exclude '*.lock' --exclude '.hub/' --exclude 'ticker_*' \
		"$SRC/$d/" "$INCOMING/$d/" || finish 2 "rsync $d failed"
done

for db in $DBS; do
	[ -f "$SRC/$db" ] || continue
	as_user mkdir -p "$INCOMING/$(dirname "$db")"
	# rsync above copied cron/ including a live executions.db; replace it.
	as_user rm -f "$INCOMING/$db"
	as_user "$SQLITE" "$SRC/$db" ".timeout 30000" ".backup '$INCOMING/$db'" 2>>"$LOG" ||
		finish 2 "sqlite .backup of $db failed"
	check=$(as_user "$SQLITE" "$INCOMING/$db" "PRAGMA integrity_check;" 2>&1)
	[ "$check" = "ok" ] || finish 2 "integrity_check of the copied $db failed: $check"
	# The copy is still in WAL mode, so opening it to check it leaves -shm and
	# an empty -wal behind. Empty means nothing of the copy lives there.
	if [ ! -s "$INCOMING/$db-wal" ]; then
		as_user rm -f "$INCOMING/$db-wal" "$INCOMING/$db-shm"
	fi
done

# --- shrink guard ---------------------------------------------------------

if [ -f "$DEST/current/state.db" ] && [ "$FORCE" -eq 0 ]; then
	old=$(stat -f %z "$DEST/current/state.db")
	new=$(stat -f %z "$INCOMING/state.db")
	if [ "$old" -gt 0 ] && [ $((new * 100 / old)) -lt "$SHRINK_LIMIT_PCT" ]; then
		finish 1 "refused: state.db shrank from $old to $new bytes (below ${SHRINK_LIMIT_PCT}%). Was Hermes reset? Kept the previous copy. If intended: sudo /usr/local/sbin/hermes-backup.sh --force"
	fi
fi

# --- unchanged? -----------------------------------------------------------

# Leave current/ untouched when nothing changed, so tank-snapshot sees no
# writes and skips the snapshot. See design 6.
if [ -d "$DEST/current" ] &&
	as_user diff -rq -x MANIFEST "$INCOMING" "$DEST/current" >/dev/null 2>&1; then
	as_user rm -rf "$INCOMING"
	INCOMING=
	log "unchanged since the last copy; left $DEST/current as it was"
	finish 0
fi

# --- manifest -------------------------------------------------------------

commit=$(as_user git -C "$SRC/hermes-agent" rev-parse HEAD 2>/dev/null)
version=$(as_user "$SRC/hermes-agent/venv/bin/python" -m hermes_cli.main --version 2>/dev/null | head -1)
copied=$(cd "$INCOMING" && ls -A | tr '\n' ' ')
skipped=$(cd "$SRC" && for e in $(ls -A); do [ -e "$INCOMING/$e" ] || printf '%s ' "$e"; done)
as_user sh -c "cat >'$INCOMING/MANIFEST'" <<EOF
taken:          $(date '+%Y-%m-%d %H:%M:%S %z')
host:           $(hostname -s)
source:         $SRC
hermes:         ${version:-unknown}
hermes-agent:   ${commit:-unknown}

Restore: reinstall Hermes, check out the commit above in ~/.hermes/hermes-agent
(so state.db's schema matches), stop Hermes, copy everything here into
~/.hermes, start Hermes.

copied:  $copied
not copied (reinstallable, caches, or new — check this list after upgrades):
         $skipped
EOF

# --- swap -----------------------------------------------------------------

as_user rm -rf "$DEST/.previous"
if [ -d "$DEST/current" ]; then
	as_user mv "$DEST/current" "$DEST/.previous" || finish 2 "could not move current aside"
fi
as_user mv "$INCOMING" "$DEST/current" || {
	as_user mv "$DEST/.previous" "$DEST/current"
	finish 2 "could not move .incoming into place; restored the previous copy"
}
INCOMING=
as_user rm -rf "$DEST/.previous"

log "copied to $DEST/current ($(du -sh "$DEST/current" | cut -f1)), hermes-agent ${commit:-unknown}"
finish 0
