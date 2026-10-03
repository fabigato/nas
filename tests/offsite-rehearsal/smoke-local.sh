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
#   - the read-back check's `restic diff` parsing, which needs a parent snapshot
#     and therefore cannot run on a virgin repository
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
reset_stubs() {
	STUB_HEALTH=ONLINE; STUB_SCAN=; STUB_MOUNTED=yes
	STUB_SCLASS_BAD=; STUB_AWS=
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

# Incompressible, so restic cannot dedupe the change away and the read-back
# check has real distinct bytes to compare.
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

# --- stub aws: healthy unless STUB_SCLASS_BAD is set ---
cat >"$T/bin/aws" <<'STUB'
#!/bin/sh
prev=; pfx=
for a in "$@"; do
	[ "$prev" = --prefix ] && pfx=$a
	prev=$a
done
case "$pfx" in
data/)
	# what a half-transitioned repository looks like: older packs cold,
	# the last week still warm
	printf 'DEEP_ARCHIVE\tDEEP_ARCHIVE\tDEEP_ARCHIVE\tSTANDARD\n' ;;
*)
	# metadata. A prefix with NO matching objects is the common case —
	# locks/ is empty almost always — and the AWS CLI prints the literal
	# string "None" for it, because Contents is absent from the response
	# and --output text renders null that way. Emitting "" here instead
	# was a fake kinder than reality, and it hid a false-positive alert
	# that fired on the real bucket within the hour.
	if [ -n "${STUB_SCLASS_BAD:-}" ]; then
		printf 'index/9f2a1c\tDEEP_ARCHIVE\n'
	else
		printf 'None\n'
	fi ;;
esac
exit 0
STUB

chmod +x "$T/bin/zpool" "$T/bin/zfs" "$T/bin/aws"

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
		TANK_OFFSITE_RESTIC="$RESTIC_BIN" \
		TANK_OFFSITE_MOUNT_ROOT="$T/mnt" \
		TANK_OFFSITE_CONF_DIR="$T/conf" \
		TANK_OFFSITE_STATE_DIR="$T/state" \
		TANK_OFFSITE_CACHE_DIR="$T/cache" \
		TANK_OFFSITE_LOG="$T/log" \
		TANK_OFFSITE_LAST="$T/last" \
		TANK_OFFSITE_HEARTBEAT="$T/heartbeat" \
		TANK_OFFSITE_ZEDRC="$T/conf/zed.rc" \
		TANK_OFFSITE_LOCKDIR="$T/lock" \
		TANK_OFFSITE_AWS="${STUB_AWS:-$T/bin/aws}" \
		STUB_SCLASS_BAD="${STUB_SCLASS_BAD:-}" \
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
echo "4. A changed file, forced run — read-back check must exercise restic diff"
reset_stubs
dd if=/dev/urandom of="$T/mnt/my_media/clip-a.bin" bs=64k count=9 2>/dev/null
: >"$T/log"
run_offsite --force --only my_media; rc=$?
check "exit code" "$rc" 0
if grep -q 'read-back: OK' "$T/log"; then
	ok "read-back verified a changed file against the source"
else
	bad "read-back verified a changed file against the source"
	sed 's/^/        /' "$T/log"
fi
if grep -q 'read-back: checked [1-9]' "$T/log"; then
	ok "read-back checked at least one file"
else
	bad "read-back checked at least one file (parsed restic diff?)"
fi

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
echo "19. Metadata staying in Standard is asserted every run"
reset_stubs
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code" "$rc" 0
grep -q 'storage classes OK' "$T/log" && ok "asserted metadata is all STANDARD" || bad "asserted metadata is all STANDARD"
grep -q 'storage-class:\[ok\]' "$T/log" && ok "verdict carries the result" || bad "verdict carries the result"
# The data/ distribution is an observation, not an assertion: packs under 7
# days old are legitimately still warm, so there is no threshold to alert on.
grep -q 'DEEP_ARCHIVE' "$T/log" && ok "logs the data/ distribution" || bad "logs the data/ distribution"
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
echo "21. A missing aws CLI is reported, not silently skipped"
reset_stubs
STUB_AWS=/nonexistent/aws
: >"$T/log"
run_offsite --force --only documents; rc=$?
check "exit code unaffected" "$rc" 0
grep -q 'storage-class check: .* not found — SKIPPED' "$T/log" && ok "says it could not check" || bad "says it could not check"
grep -q 'storage-class:\[skipped\]' "$T/log" && ok "skip is visible in the verdict, not silent" || bad "skip is visible in the verdict, not silent"

echo
echo "================================================"
echo "  $PASS passed, $FAIL failed"
echo "================================================"
[ "$FAIL" = 0 ] || exit 1
