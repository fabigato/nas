#!/bin/sh
#
# smoke-local.sh — drive tank-offsite.sh against a LOCAL restic repository and
# stubbed ZFS binaries. No AWS, no network, no pool. Runs in a few seconds.
#
# WHAT THIS IS FOR, AND WHAT IT IS NOT
#
# It proves BEHAVIOUR, not CONTEXT. Everything here runs as a normal user from a
# terminal, so it says nothing about TCC, the launchd environment or the empty
# PATH a daemon inherits — the lesson that cost three cold boots. A kickstart
# proves that half and neither substitutes for the other.
#
# What it does reach is the set of branches a first real run cannot:
#
#   - the unmounted-dataset refusal, which on the real pool would mean
#     deliberately exporting `tank` to test it
#   - the empty-mountpoint refusal, same
#   - the scrub deferral, which otherwise only happens on the 1st of the month
#   - --fix-classes, which on the real bucket means a Glacier thaw and 12 hours
#   - not-due-ness, which on the real thing takes a month to observe
#
# The guards are exercised for real against stub binaries rather than skipped
# with a flag. tank-offsite.sh has no bypass switch, on purpose: a guard that
# can be turned off in testing is a guard that gets shipped untested.
#
# Usage:  sh smoke-local.sh

set -u

SCRIPT=${SCRIPT:-$(cd "$(dirname "$0")/../../scripts/nas-offsite" && pwd)/tank-offsite.sh}
RESTIC_BIN=${RESTIC_BIN:-$(command -v restic)}

[ -f "$SCRIPT" ] || { echo "cannot find tank-offsite.sh at $SCRIPT"; exit 1; }
[ -n "$RESTIC_BIN" ] || { echo "restic is not installed"; exit 1; }

T=$(mktemp -d /tmp/offsite-smoke.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT

# THE STUB KNOBS ARE GLOBALS WITH AN EXPLICIT RESET, AND THAT IS NOT TIDINESS.
#
# `STUB_MOUNTED=no run_offsite ...` looks like a one-shot override. For an
# external command it is. For a FUNCTION, bash leaves the assignment in place
# after the call — POSIX says the behaviour is unspecified and bash keeps it.
# So the first version of this suite leaked STUB_MOUNTED=no out of test 6 and
# STUB_HEALTH=SUSPENDED out of test 8, and tests 7 and 9 then ran against a
# pool that was unmounted and suspended. Test 9 duly reported that --dry-run
# "refuses", which is true and had nothing to do with --dry-run.
#
# A suite whose fixtures leak forward does not report on the code, it reports on
# the order its own tests happen to run in.
STUB_HEALTH=ONLINE
STUB_SCAN=
STUB_MOUNTED=yes
STUB_SCLASS_BAD=
STUB_AWS=
STUB_BACKUP_UNCHANGED=
STUB_FORGET_FAIL=
STUB_TREES_CLASS=
STUB_CONTENT_CLASS=
STUB_THAWED=
STUB_INDEX_FAIL=
STUB_CHECK_COLD=
reset_stubs() {
	STUB_HEALTH=ONLINE; STUB_SCAN=; STUB_MOUNTED=yes
	STUB_SCLASS_BAD=; STUB_AWS=; STUB_BACKUP_UNCHANGED=; STUB_FORGET_FAIL=
	STUB_TREES_CLASS=; STUB_CONTENT_CLASS=; STUB_THAWED=; STUB_INDEX_FAIL=; STUB_CHECK_COLD=
	: >"$T/aws.calls"; : >"$T/restic.calls"
}

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (got $2, want $3)"; fi; }

# ------------------------------------------------------------------ fixtures

mkdir -p "$T/mnt/my_media" "$T/mnt/documents" "$T/conf" "$T/state" "$T/cache" "$T/bin"
# A chosen folder inside the otherwise-excluded `media` dataset, which is the
# case dataset-granular targets could not express.
mkdir -p "$T/mnt/media/concerts" "$T/mnt/media/dont-back-this-up"

# Incompressible, so restic cannot dedupe the change away.
dd if=/dev/urandom of="$T/mnt/my_media/clip-a.bin" bs=64k count=8 2>/dev/null
dd if=/dev/urandom of="$T/mnt/my_media/clip-b.bin" bs=64k count=8 2>/dev/null
echo "notes" >"$T/mnt/documents/notes.txt"
echo "a keeper" >"$T/mnt/media/concerts/set-list.txt"
echo "re-downloadable" >"$T/mnt/media/dont-back-this-up/movie.txt"
# The exclude that matters on this pool: Finder writes .DS_Store on DISPLAY, and
# on my_media a rewrite costs ~100x its size in `written` at recordsize=1M.
printf 'finder junk' >"$T/mnt/my_media/.DS_Store"
# The rest of the macOS cruft family. .Spotlight-V100 is the one that actually
# bit on 2026-10-03: SIP makes it unreadable even as root, restic exits 3, and
# the run alerts every night forever unless it is never opened in the first
# place. Here they are merely present, which is enough to prove exclusion.
mkdir -p "$T/mnt/my_media/.Spotlight-V100" "$T/mnt/my_media/.fseventsd" \
	"$T/mnt/my_media/.Trashes" "$T/mnt/my_media/.TemporaryItems" \
	"$T/mnt/my_media/.DocumentRevisions-V100"
for d in .Spotlight-V100 .fseventsd .Trashes .TemporaryItems .DocumentRevisions-V100; do
	echo cruft >"$T/mnt/my_media/$d/index"
done

# --- stub zpool: healthy, no scan running ---
cat >"$T/bin/zpool" <<'STUB'
#!/bin/sh
case "$1" in
list)   echo "${STUB_HEALTH:-ONLINE}" ;;
status) echo "  pool: tank"; echo " state: ${STUB_HEALTH:-ONLINE}"
        [ -n "${STUB_SCAN:-}" ] && echo "  scan: $STUB_SCAN"
        echo "config:" ;;
esac
exit 0
STUB

# --- stub zfs: every dataset mounted unless told otherwise ---
cat >"$T/bin/zfs" <<'STUB'
#!/bin/sh
echo "${STUB_MOUNTED:-yes}"
exit 0
STUB

# --- stub aws: an S3 that honours restic's storage-class choice ---
# data/ is listed from the real local repository, with tree packs in
# STUB_TREES_CLASS (default STANDARD) and content in STUB_CONTENT_CLASS
# (default DEEP_ARCHIVE) — what restic's -o s3.storage-class=DEEP_ARCHIVE
# produces on the real bucket. Every call is recorded in $T/aws.calls so a test
# can see what was asked of S3, and what was not.
#
# head-object reports a thaw as not requested unless STUB_THAWED, in which case
# it is complete. restore-object and copy-object succeed and change nothing:
# the tests read the calls, not the outcome.
cat >"$T/bin/aws" <<STUB
#!/bin/sh
echo "\$*" >>"$T/aws.calls"
case "\$2" in
head-object)
	if [ -n "\${STUB_THAWED:-}" ]; then
		echo 'ongoing-request="false", expiry-date="Fri, 17 Oct 2026 00:00:00 GMT"'
	else
		echo None
	fi
	exit 0 ;;
list-objects-v2) ;;
*) exit 0 ;;
esac
prev=; pfx=
for a in "\$@"; do
	[ "\$prev" = --prefix ] && pfx=\$a
	prev=\$a
done
case "\$pfx" in
data/)
	trees=\$(for i in \$("$RESTIC_BIN" list index); do "$RESTIC_BIN" cat index "\$i"; done |
		/usr/bin/jq -r '.packs[] | select(any(.blobs[]; .type == "tree")) | .id')
	for f in "$T"/repo/data/*/*; do
		id=\${f##*/}
		dir=\${f%/*}
		if printf '%s\n' "\$trees" | grep -qx "\$id"; then
			c=\${STUB_TREES_CLASS:-STANDARD}
		else
			c=\${STUB_CONTENT_CLASS:-DEEP_ARCHIVE}
		fi
		printf 'data/%s/%s\t%s\n' "\${dir##*/}" "\$id" "\$c"
	done ;;
*)
	# metadata. A prefix with NO matching objects is the common case —
	# locks/ is empty almost always — and the AWS CLI prints the literal
	# string "None" for it, because Contents is absent from the response
	# and --output text renders null that way. Emitting "" here instead
	# was a fake kinder than reality, and it hid a false-positive alert
	# that fired on the real bucket within the hour.
	if [ -n "\${STUB_SCLASS_BAD:-}" ]; then
		printf 'index/9f2a1c\tDEEP_ARCHIVE\n'
	else
		printf 'None\n'
	fi ;;
esac
exit 0
STUB

# --- wrapper restic: the real one, with failures it will not do on request ---
# Every call is recorded in $T/restic.calls.
# STUB_BACKUP_UNCHANGED: a backup that finds nothing new. Real restic decides
# that here only by luck: it records the metadata of every ancestor of the
# backed-up path, and /tmp and $T are touched between runs by other processes
# and by this suite. A --dry-run prints no "snapshot ... saved" line, which is
# exactly what the script reads as unchanged. On the real pool /Volumes/tank
# does not churn, and 2026-10-07 was genuinely unchanged.
# STUB_INDEX_FAIL: an index file that cannot be read.
# STUB_CHECK_COLD: check meets tree packs in Deep Archive, as on 2026-10-10.
cat >"$T/bin/restic" <<STUB
#!/bin/sh
echo "\$*" >>"$T/restic.calls"
if [ "\$1" = cat ] && [ "\$2" = index ] && [ -n "\${STUB_INDEX_FAIL:-}" ]; then
	echo "Fatal: stub index failure" >&2
	exit 1
fi
if [ "\$1" = check ] && [ -n "\${STUB_CHECK_COLD:-}" ]; then
	echo "Load(<data/935c1c95c8>, 0, 0) failed: The operation is not valid for the object's storage class"
	echo "Fatal: repository contains errors"
	exit 1
fi
# STUB_FORGET_FAIL: forget refused, as the backup credential is by S3.
if [ "\$1" = forget ] && [ -n "\${STUB_FORGET_FAIL:-}" ]; then
	echo "Remove(<snapshot/x>) failed: AccessDenied (stub)" >&2
	exit 1
fi
if [ "\$1" = prune ] && [ -n "\${STUB_FORGET_FAIL:-}" ]; then
	echo "PRUNE RAN" >&2
fi
if [ "\$1" = backup ] && [ -n "\${STUB_BACKUP_UNCHANGED:-}" ]; then
	exec "$RESTIC_BIN" "\$@" --dry-run
fi
exec "$RESTIC_BIN" "\$@"
STUB

chmod +x "$T/bin/zpool" "$T/bin/zfs" "$T/bin/aws" "$T/bin/restic"

# An EMPTY zed.rc, so notify() takes its "no channel set" branch and logs
# instead of posting. Pointing a test suite at the live Discord webhook would
# make the channel that reports real failures indistinguishable from noise.
: >"$T/conf/zed.rc"

printf '%s' 'smoke-test-password' >"$T/conf/repo.pass"
cat >"$T/conf/backup.env" <<'EOF'
AWS_ACCESS_KEY_ID=AKIANOTUSEDBYLOCALBACKEND
AWS_SECRET_ACCESS_KEY=notusedbylocalbackend
EOF
cat >"$T/conf/targets" <<'EOF'
# path (relative to the mount root)   interval in days
my_media         30
documents         7
media/concerts   30
EOF

cat >"$T/conf/env" <<EOF
OFFSITE_BUCKET=tank-offsite-smoketest
RESTIC_REPOSITORY=$T/repo
EOF

RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" init --repository-version 2 >/dev/null 2>&1 ||
	{ echo "restic init failed"; exit 1; }

run_offsite() {
	env \
		TANK_OFFSITE_ZFS="$T/bin/zfs" \
		TANK_OFFSITE_ZPOOL="$T/bin/zpool" \
		TANK_OFFSITE_RESTIC="$T/bin/restic" \
		STUB_BACKUP_UNCHANGED="${STUB_BACKUP_UNCHANGED:-}" \
		TANK_OFFSITE_MOUNT_ROOT="$T/mnt" \
		TANK_OFFSITE_CONF_DIR="$T/conf" \
		TANK_OFFSITE_STATE_DIR="$T/state" \
		TANK_OFFSITE_CACHE_DIR="$T/cache" \
		TANK_OFFSITE_LOG="$T/log" \
		TANK_OFFSITE_LAST="$T/last" \
		TANK_OFFSITE_HEARTBEAT="$T/heartbeat" \
		TANK_OFFSITE_ZEDRC="$T/conf/zed.rc" \
		TANK_OFFSITE_LOCKDIR="$T/lock" \
		TANK_OFFSITE_DROP_TTY="$T/tty" \
		STUB_FORGET_FAIL="${STUB_FORGET_FAIL:-}" \
		TANK_OFFSITE_AWS="${STUB_AWS:-$T/bin/aws}" \
		STUB_SCLASS_BAD="${STUB_SCLASS_BAD:-}" \
		STUB_TREES_CLASS="$STUB_TREES_CLASS" \
		STUB_CONTENT_CLASS="$STUB_CONTENT_CLASS" \
		STUB_THAWED="$STUB_THAWED" \
		STUB_INDEX_FAIL="$STUB_INDEX_FAIL" \
		STUB_CHECK_COLD="$STUB_CHECK_COLD" \
		TANK_OFFSITE_LIMIT_UP=0 \
		STUB_HEALTH="$STUB_HEALTH" \
		STUB_SCAN="$STUB_SCAN" \
		STUB_MOUNTED="$STUB_MOUNTED" \
		sh "$SCRIPT" "$@" >"$T/stdout" 2>&1
}

nsnaps() {
	RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
		"$RESTIC_BIN" snapshots --json 2>/dev/null |
		python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)'
}

# Tree pack ids, straight from the repository's index — the ground truth the
# script's own tree_packs() is measured against.
tree_ids() {
	RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
		sh -c 'for i in $("$1" list index); do "$1" cat index "$i"; done' _ "$RESTIC_BIN" |
		/usr/bin/jq -r '.packs[] | select(any(.blobs[]; .type == "tree")) | .id' | sort -u
}

# --------------------------------------------------------------------- tests

echo
echo "1. First run — both targets due on an empty repository"
reset_stubs
run_offsite; rc=$?
check "exit code" "$rc" 0
check "snapshots created" "$(nsnaps)" 3
if grep -q 'my_media: due' "$T/log" && grep -q 'documents: due' "$T/log" &&
	grep -q 'media/concerts: due' "$T/log"; then
	ok "all three targets reported due"
else
	bad "all three targets reported due"
fi

# The whole point of path targets: a folder inside `media` is protected while
# the rest of the dataset, which is re-downloadable, is not.
if RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" ls latest --tag media/concerts 2>/dev/null | grep -q 'set-list.txt'; then
	ok "a chosen folder inside media was backed up"
else
	bad "a chosen folder inside media was backed up"
fi
if RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" ls latest --tag media/concerts 2>/dev/null | grep -q 'dont-back-this-up'; then
	bad "the rest of media stayed out"
else
	ok "the rest of media stayed out"
fi
check "state file name has no slash" "$(ls "$T/state" | grep -c '^media_concerts.last$')" 1

echo
echo "2. .DS_Store is excluded"
reset_stubs
if RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" ls latest 2>/dev/null | grep -q '\.DS_Store'; then
	bad ".DS_Store excluded"
else
	ok ".DS_Store excluded"
fi

echo
echo "2b. The whole macOS cruft family is excluded, not just .DS_Store"
cruft_leaked=0
for d in .Spotlight-V100 .fseventsd .Trashes .TemporaryItems .DocumentRevisions-V100; do
	if RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
		"$RESTIC_BIN" ls latest --tag my_media 2>/dev/null | grep -q "$d"; then
		bad "$d excluded"; cruft_leaked=1
	fi
done
[ "$cruft_leaked" = 0 ] && ok "all five macOS metadata dirs excluded"

echo
echo "2c. A user exclude file is honoured on top of the built-in list"
mkdir -p "$T/mnt/my_media/scratch"; echo tmp >"$T/mnt/my_media/scratch/wip.tmp"
echo 'scratch' >"$T/conf/exclude"
: >"$T/log"
run_offsite --force --only my_media >/dev/null 2>&1
if RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" ls latest --tag my_media 2>/dev/null | grep -q 'wip.tmp'; then
	bad "user exclude file honoured"
else
	ok "user exclude file honoured"
fi
rm -f "$T/conf/exclude"

echo
echo "3. Immediate re-run — nothing is due, nothing is uploaded"
reset_stubs
before=$(nsnaps)
run_offsite; rc=$?
check "exit code" "$rc" 0
check "no new snapshots" "$(nsnaps)" "$before"
grep -q 'not due' "$T/log" && ok "logged not-due" || bad "logged not-due"

echo
echo "4. A changed file goes up with content bound for Deep Archive"
reset_stubs
dd if=/dev/urandom of="$T/mnt/my_media/clip-a.bin" bs=64k count=9 2>/dev/null
: >"$T/log"
run_offsite --force --only my_media; rc=$?
check "exit code" "$rc" 0
# The option that keeps trees warm and sends content cold. Without it every
# pack lands in Standard, which breaks nothing and costs ~13x as much.
grep '^backup ' "$T/restic.calls" | grep -q -- '-o s3.storage-class=DEEP_ARCHIVE' &&
	ok "backup passes s3.storage-class=DEEP_ARCHIVE" || bad "backup passes s3.storage-class=DEEP_ARCHIVE"
grep -q 'read-back' "$T/log" && bad "no read-back is attempted on cold content" || ok "no read-back is attempted on cold content"

echo
echo "5. THE GUARD THAT MATTERS — an empty mountpoint must refuse, not record"
reset_stubs
# The branch the piped-while-loop bug disabled. Measured, not assumed: with the
# bug present this assertion fails on the EXIT CODE while "NO snapshot was
# recorded" still passes. The guard was never the part that broke — it fired,
# logged and refused correctly. What broke was that the script then exited 0
# with `ran:[none] failed:[none]`, i.e. reported a clean run of a backup that
# had not happened. So assert the exit code, not just the absence of a snapshot:
# checking only the latter would have passed against the broken code.
before=$(nsnaps)
mkdir -p "$T/empty/my_media" "$T/empty/documents" "$T/empty/media/concerts"
echo x >"$T/empty/documents/f"; echo x >"$T/empty/media/concerts/f"
: >"$T/log"
env TANK_OFFSITE_MOUNT_ROOT="$T/empty" \
	TANK_OFFSITE_ZFS="$T/bin/zfs" TANK_OFFSITE_ZPOOL="$T/bin/zpool" \
	TANK_OFFSITE_RESTIC="$RESTIC_BIN" TANK_OFFSITE_CONF_DIR="$T/conf" \
	TANK_OFFSITE_STATE_DIR="$T/state" TANK_OFFSITE_CACHE_DIR="$T/cache" \
	TANK_OFFSITE_LOG="$T/log" TANK_OFFSITE_LAST="$T/last" \
	TANK_OFFSITE_HEARTBEAT="$T/heartbeat" TANK_OFFSITE_ZEDRC="$T/conf/zed.rc" \
	TANK_OFFSITE_LOCKDIR="$T/lock" STUB_MOUNTED=yes \
	sh "$SCRIPT" --force --only my_media >"$T/stdout" 2>&1
rc=$?
check "exit code reports a failed target" "$rc" 2
check "NO snapshot was recorded" "$(nsnaps)" "$before"
grep -q 'EMPTY' "$T/log" && ok "refusal names the empty mountpoint" || bad "refusal names the empty mountpoint"

echo
echo "6. An unmounted dataset must refuse"
reset_stubs
before=$(nsnaps)
: >"$T/log"
STUB_MOUNTED=no
run_offsite --force --only my_media; rc=$?
check "exit code reports a failed target" "$rc" 2
check "NO snapshot was recorded" "$(nsnaps)" "$before"

echo
echo "7. A scrub in progress must defer, not fail"
reset_stubs
: >"$T/log"
STUB_SCAN="scrub in progress since Tue Sep  1 03:00:00 2026"
run_offsite --force; rc=$?
check "exit code is deferral" "$rc" 3
grep -q 'deferring' "$T/log" && ok "logged the deferral" || bad "logged the deferral"

echo
echo "8. An unhealthy pool must refuse"
reset_stubs
: >"$T/log"
STUB_HEALTH=SUSPENDED
run_offsite --force; rc=$?
check "exit code is a refusal" "$rc" 1

echo
echo "9. --dry-run changes nothing"
reset_stubs
before=$(nsnaps)
run_offsite --dry-run --force; rc=$?
check "exit code" "$rc" 0
check "no new snapshots" "$(nsnaps)" "$before"

echo
echo "10. A run already in progress must defer quietly, not alert"
reset_stubs
# $$ is this suite, which is unquestionably alive, so the liveness check must
# conclude "still running". A 200 GB month takes ~30 h and WILL overlap the
# next nightly fire, so this is ordinary operation, not a corner case.
before=$(nsnaps)
mkdir -p "$T/lock" && echo $$ >"$T/lock/pid"
: >"$T/log"
run_offsite --force; rc=$?
check "exit code is deferral" "$rc" 3
check "no new snapshots" "$(nsnaps)" "$before"
grep -q 'still going' "$T/log" && ok "named the running pid" || bad "named the running pid"
if grep -qi 'DELIVERY FAILED\|notify: delivered' "$T/log"; then
	bad "deferral stayed off the notification channel"
else
	ok "deferral stayed off the notification channel"
fi
rm -rf "$T/lock"

echo
echo "11. A stale lock from a dead run must be cleared, not obeyed forever"
reset_stubs
before=$(nsnaps)
mkdir -p "$T/lock"
# A pid that cannot be alive. Without the liveness check this lock would block
# every future run for good, which is a worse bug than the one it prevents.
echo 999999 >"$T/lock/pid"
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code" "$rc" 0
grep -q 'stale lock' "$T/log" && ok "logged clearing the stale lock" || bad "logged clearing the stale lock"
if [ "$(nsnaps)" -gt "$before" ] || grep -q 'nothing changed' "$T/log"; then
	ok "the run proceeded"
else
	bad "the run proceeded"
fi

echo
echo "12. The lock is released on exit, so the next run is not blocked"
reset_stubs
run_offsite --force --only documents; rc=$?
check "exit code" "$rc" 0
[ -d "$T/lock" ] && bad "lock directory cleaned up" || ok "lock directory cleaned up"

echo
echo "13. A stale path must take out ONLY itself, not every other backup"
reset_stubs
# The failure this guards against is config drift: a folder inside media gets
# renamed, and every offsite backup — including my_media — stops. You would
# still be alerted, so refusing everything buys nothing but collateral.
before=$(nsnaps)
cp "$T/conf/targets" "$T/conf/targets.bak"
echo "media/typoed-folder 30" >>"$T/conf/targets"
: >"$T/log"
run_offsite --force; rc=$?
check "exit code reports a failed target" "$rc" 2
grep -q 'does not exist' "$T/log" && ok "alert names the missing path" || bad "alert names the missing path"
if [ "$(nsnaps)" -gt "$before" ] || grep -q 'nothing changed' "$T/log"; then
	ok "the healthy targets were still backed up"
else
	bad "the healthy targets were still backed up"
fi
grep -q 'my_media: due' "$T/log" && ok "my_media still ran despite the bad line" || bad "my_media still ran despite the bad line"
mv "$T/conf/targets.bak" "$T/conf/targets"

echo
echo "14. A malformed interval must refuse"
reset_stubs
cp "$T/conf/targets" "$T/conf/targets.bak"
echo "documents weekly" >>"$T/conf/targets"
: >"$T/log"
run_offsite --force; rc=$?
check "exit code is a refusal" "$rc" 1
grep -q "bad interval" "$T/log" && ok "refusal names the bad interval" || bad "refusal names the bad interval"
mv "$T/conf/targets.bak" "$T/conf/targets"

echo
echo "15. A path escaping the mount root must refuse"
reset_stubs
cp "$T/conf/targets" "$T/conf/targets.bak"
echo "../../etc 30" >>"$T/conf/targets"
: >"$T/log"
run_offsite --force; rc=$?
check "exit code is a refusal" "$rc" 1
mv "$T/conf/targets.bak" "$T/conf/targets"

echo
echo "16. --only with a name that is in no target must refuse, not no-op"
reset_stubs
before=$(nsnaps)
: >"$T/log"
run_offsite --force --only my_medai; rc=$?
check "exit code is a refusal" "$rc" 1
check "no new snapshots" "$(nsnaps)" "$before"

echo
echo "17. An unreadable file must NOT become an infinite retry loop"
reset_stubs
# restic exits 3 for "some source data could not be read (incomplete snapshot
# created)". The snapshot EXISTS. Treating that as a failure means the state
# file is never written, so the next run finds the target due and repeats the
# whole thing — which is exactly what happened on the real pool between
# 2026-09-30 and 2026-10-03: nightly re-walks of 491 GiB and a nightly alert.
echo secret >"$T/mnt/documents/unreadable.txt"
chmod 000 "$T/mnt/documents/unreadable.txt"
rm -f "$T/state/documents.last"
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code reports the incomplete snapshot" "$rc" 2
if [ -f "$T/state/documents.last" ]; then
	ok "STATE WAS STILL WRITTEN — no retry loop"
else
	bad "STATE WAS STILL WRITTEN — no retry loop"
fi
grep -q 'could not be read' "$T/log" && ok "alerted about the real unreadable file" || bad "alerted about the real unreadable file"
# restic emits a blank line after every error. Filtering the error text alone
# leaves the blanks behind, which is the same log flood minus the words.
if awk 'BEGIN{r=0;m=0} /^[[:space:]]*$/{r++; if(r>m)m=r; next} {r=0} END{exit !(m>1)}' "$T/log"; then
	bad "no runs of blank lines left in the log"
else
	ok "no runs of blank lines left in the log"
fi

echo
echo "18. ...and the next run then correctly reports not-due"
reset_stubs
: >"$T/log"
run_offsite --only documents; rc=$?
check "exit code" "$rc" 0
grep -q 'documents: not due' "$T/log" && ok "not due, so the loop really is broken" || bad "not due, so the loop really is broken"
chmod 644 "$T/mnt/documents/unreadable.txt"

echo
echo "19. Metadata and tree packs staying in Standard is asserted every run"
reset_stubs
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code" "$rc" 0
ntrees=$(tree_ids | wc -l | tr -d ' ')
grep -q "storage classes OK: metadata and $ntrees tree pack(s) STANDARD$" "$T/log" &&
	ok "asserted metadata and all $ntrees tree packs are STANDARD" ||
	{ bad "asserted metadata and all $ntrees tree packs are STANDARD"; grep 'storage' "$T/log" | sed 's/^/        /'; }
grep -q 'storage-class:\[ok\]' "$T/log" && ok "verdict carries the result" || bad "verdict carries the result"
# An empty prefix is the common case, not an edge case. AWS prints "None"
# for it, which must not read as an object in the wrong storage class.
grep -q 'None' "$T/log" && bad "the literal None never reaches the verdict" || ok "the literal None never reaches the verdict"

echo
echo "20. Metadata going cold must alert — restic could not open the repo at all"
reset_stubs
STUB_SCLASS_BAD=1
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code reports the violation" "$rc" 2
grep -q 'METADATA has left Standard' "$T/log" && ok "alert names the failure" || bad "alert names the failure"
grep -q 'storage-class:\[VIOLATED\]' "$T/log" && ok "verdict carries the violation" || bad "verdict carries the violation"

echo
echo "20b. Tree packs going cold must alert — what the lifecycle rule did on 2026-10-10"
reset_stubs
STUB_TREES_CLASS=DEEP_ARCHIVE
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code reports the violation" "$rc" 2
grep -q 'TREE pack(s) are out of Standard' "$T/log" && ok "alert names tree packs" || bad "alert names tree packs"
grep -q 'storage-class:\[VIOLATED\]' "$T/log" && ok "verdict carries the violation" || bad "verdict carries the violation"

echo
echo "20c. Content left in Standard is logged, not alerted — it costs money, breaks nothing"
reset_stubs
STUB_CONTENT_CLASS=STANDARD
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code" "$rc" 0
grep -q 'content pack(s) still in STANDARD' "$T/log" && ok "logs the warm content" || bad "logs the warm content"

echo
echo "20d. An unreadable index is reported as skipped, never as ok"
reset_stubs
STUB_INDEX_FAIL=1
: >"$T/log"
run_offsite --force --only documents; rc=$?
grep -q 'could not read restic.s index to find tree packs — SKIPPED' "$T/log" && ok "says it could not check" || bad "says it could not check"
grep -q 'storage-class:\[skipped\]' "$T/log" && ok "verdict says skipped" || bad "verdict says skipped"

echo
echo "20e. A check that meets cold trees says so — not \"bookkeeping does not agree\""
reset_stubs
STUB_CHECK_COLD=1
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code" "$rc" 2
grep -q 'could not read tree packs: they are in Deep Archive' "$T/log" && ok "names the cause" || bad "names the cause"
grep -q 'bookkeeping does not' "$T/log" && bad "does not call it corruption" || ok "does not call it corruption"

echo
echo "21. A missing aws CLI is reported, not silently skipped"
reset_stubs
STUB_AWS=/nonexistent/aws
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code unaffected" "$rc" 0
grep -q 'storage-class check: .* not found — SKIPPED' "$T/log" && ok "says it could not check" || bad "says it could not check"
grep -q 'storage-class:\[skipped\]' "$T/log" && ok "skip is visible in the verdict, not silent" || bad "skip is visible in the verdict, not silent"

echo
echo "22. An unchanged run writes state and passes"
reset_stubs
STUB_BACKUP_UNCHANGED=1
: >"$T/log"
run_offsite --force --only media/concerts; rc=$?
check "exit code" "$rc" 0
grep -q 'nothing changed' "$T/log" && ok "really was an unchanged run" || bad "really was an unchanged run"

PRUNE_CRED='AWS_ACCESS_KEY_ID=AKIAPRUNESTUB
AWS_SECRET_ACCESS_KEY=prunestub'

echo
echo "23. --fix-classes --dry-run reads, and asks S3 to change nothing"
reset_stubs
STUB_TREES_CLASS=DEEP_ARCHIVE; STUB_CONTENT_CLASS=STANDARD
run_offsite --dry-run --fix-classes </dev/null; rc=$?
check "exit code" "$rc" 0
grep -q 'tree, cold, would request a thaw' "$T/stdout" && ok "shows the thaws it would ask for" || bad "shows the thaws it would ask for"
grep -q 'content, would copy to DEEP_ARCHIVE' "$T/stdout" && ok "shows the content it would move" || bad "shows the content it would move"
grep -qE 'restore-object|copy-object' "$T/aws.calls" && bad "no mutating call reached S3" || ok "no mutating call reached S3"

echo
echo "24. --fix-classes without the prune credential refuses"
reset_stubs
printf '' | run_offsite --fix-classes; rc=$?
check "exit code" "$rc" 1
grep -q 'stdin did not hold' "$T/log" && ok "says what stdin was missing" || bad "says what stdin was missing"
cat "$T/conf/backup.env" | run_offsite --fix-classes; rc=$?
check "backup credential: exit code" "$rc" 1
grep -q 'that is the backup credential' "$T/log" && ok "names the wrong credential" || bad "names the wrong credential"

echo
echo "24b. THE REFUSAL THAT MATTERS — no index, no moves"
# Without the list of tree packs every pack looks like content, and a tree
# pack sent to Deep Archive is the exact damage this command repairs.
reset_stubs
STUB_INDEX_FAIL=1; STUB_CONTENT_CLASS=STANDARD
printf '%s\n' "$PRUNE_CRED" | run_offsite --fix-classes; rc=$?
check "exit code" "$rc" 2
grep -q 'tree packs cannot be told from content — nothing done' "$T/log" && ok "says why" || bad "says why"
grep -qE 'restore-object|copy-object' "$T/aws.calls" && bad "no mutating call reached S3" || ok "no mutating call reached S3"

echo
echo "24c. Cold trees get a Standard-tier thaw, and are not copied until it lands"
reset_stubs
STUB_TREES_CLASS=DEEP_ARCHIVE
ntrees=$(tree_ids | wc -l | tr -d ' ')
printf '%s\n' "$PRUNE_CRED" | run_offsite --fix-classes; rc=$?
check "exit code says come back later" "$rc" 3
check "one thaw per tree pack" "$(grep -c '^s3api restore-object' "$T/aws.calls")" "$ntrees"
grep '^s3api restore-object' "$T/aws.calls" | grep -qv 'Tier=Standard' && bad "every thaw is Standard tier" || ok "every thaw is Standard tier"
check "nothing copied yet" "$(grep -c '^s3api copy-object' "$T/aws.calls")" 0
grep -q 'Run this again in ~12 hours' "$T/stdout" && ok "says when to come back" || bad "says when to come back"

echo
echo "24d. Once thawed, trees are copied back to STANDARD"
reset_stubs
STUB_TREES_CLASS=DEEP_ARCHIVE; STUB_THAWED=1
printf '%s\n' "$PRUNE_CRED" | run_offsite --fix-classes; rc=$?
check "exit code" "$rc" 0
check "one copy per tree pack, to STANDARD" "$(grep '^s3api copy-object' "$T/aws.calls" | grep -c -- '--storage-class STANDARD')" "$ntrees"
grep -q 'Every pack is in its class' "$T/stdout" && ok "says it is done" || bad "says it is done"

echo
echo "24e. Warm content goes to DEEP_ARCHIVE, and no tree ever does"
reset_stubs
STUB_CONTENT_CLASS=STANDARD
printf '%s\n' "$PRUNE_CRED" | run_offsite --fix-classes; rc=$?
check "exit code" "$rc" 0
ncontent=$(find "$T/repo/data" -type f | wc -l | tr -d ' '); ncontent=$((ncontent - ntrees))
check "one copy per content pack, to DEEP_ARCHIVE" "$(grep '^s3api copy-object' "$T/aws.calls" | grep -c -- '--storage-class DEEP_ARCHIVE')" "$ncontent"
cold_tree=0
for id in $(tree_ids); do
	grep '^s3api copy-object' "$T/aws.calls" | grep -q "$id" && cold_tree=1
done
check "tree packs sent to Deep Archive" "$cold_tree" 0
grep -q 'prunestub' "$T/log" && bad "secret never reaches the log" || ok "secret never reaches the log"

echo
echo "25. --drop shows ONLY the snapshot it will forget"
reset_stubs
drop_id=$(RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" snapshots --json --tag documents 2>/dev/null |
	grep -o '"short_id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
other_id=$(RESTIC_REPOSITORY="$T/repo" RESTIC_PASSWORD_FILE="$T/conf/repo.pass" \
	"$RESTIC_BIN" snapshots --json --tag my_media 2>/dev/null |
	grep -o '"short_id":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
before=$(nsnaps)
echo "$drop_id" >"$T/tty"
run_offsite --dry-run --drop "$drop_id" </dev/null; rc=$?
check "exit code" "$rc" 0
grep -q "$drop_id" "$T/stdout" && ok "lists the snapshot being dropped" || bad "lists the snapshot being dropped"
grep -q "$other_id" "$T/stdout" && bad "does not list any other snapshot" || ok "does not list any other snapshot"
grep -q "other $((before - 1)) snapshot(s) in the repository are untouched" "$T/stdout" &&
	ok "says how many are untouched" || bad "says how many are untouched"
check "dry run forgot nothing" "$(nsnaps)" "$before"

echo
echo "26. --drop with an id that matches nothing refuses before asking"
reset_stubs
echo deadbeef >"$T/tty"
run_offsite --drop deadbeef </dev/null; rc=$?
check "exit code" "$rc" 1
grep -q 'matches 0 snapshots' "$T/log" && ok "says it matched nothing" || bad "says it matched nothing"
grep -q 'Type the snapshot id' "$T/stdout" && bad "never reached the confirmation prompt" || ok "never reached the confirmation prompt"
check "nothing forgotten" "$(nsnaps)" "$before"

echo
echo "27. --drop without the prune credential on stdin refuses"
reset_stubs
echo "$drop_id" >"$T/tty"
printf '' | run_offsite --drop "$drop_id"; rc=$?
check "exit code" "$rc" 1
grep -q 'stdin did not hold' "$T/log" && ok "says what stdin was missing" || bad "says what stdin was missing"
check "nothing forgotten" "$(nsnaps)" "$before"

echo
echo "28. --drop with the BACKUP credential refuses — it cannot delete"
reset_stubs
cat "$T/conf/backup.env" | run_offsite --drop "$drop_id"; rc=$?
check "exit code" "$rc" 1
grep -q 'that is the backup credential' "$T/log" && ok "names the wrong credential" || bad "names the wrong credential"
check "nothing forgotten" "$(nsnaps)" "$before"

echo
echo "29. A forget that fails stops the drop — no prune, no \"dropped\""
reset_stubs
STUB_FORGET_FAIL=1
printf 'AWS_ACCESS_KEY_ID=AKIAPRUNESTUB\nAWS_SECRET_ACCESS_KEY=prunestub\n' |
	run_offsite --drop "$drop_id"; rc=$?
check "exit code" "$rc" 2
grep -q "forget $drop_id failed" "$T/log" && ok "reports the forget failure" || bad "reports the forget failure"
grep -q 'PRUNE RAN' "$T/stdout" && bad "prune did not run" || ok "prune did not run"
grep -q "dropped $drop_id" "$T/log" && bad "does not log dropped" || ok "does not log dropped"

echo
echo "30. --drop with the prune credential forgets exactly one snapshot"
reset_stubs
printf 'AWS_ACCESS_KEY_ID=AKIAPRUNESTUB\nAWS_SECRET_ACCESS_KEY=prunestub\n' |
	run_offsite --drop "$drop_id"; rc=$?
check "exit code" "$rc" 0
check "one snapshot fewer" "$(nsnaps)" "$((before - 1))"
grep '^prune ' "$T/restic.calls" | grep -q -- '-o s3.storage-class=DEEP_ARCHIVE' &&
	ok "prune passes s3.storage-class=DEEP_ARCHIVE" || bad "prune passes s3.storage-class=DEEP_ARCHIVE"
grep -q "dropped $drop_id" "$T/log" && ok "logged dropped" || bad "logged dropped"
grep -q 'prunestub' "$T/log" && bad "secret never reaches the log" || ok "secret never reaches the log"

echo
echo "================================================"
echo "  $PASS passed, $FAIL failed"
echo "================================================"
[ "$FAIL" = 0 ] || exit 1
