#!/bin/sh
#
# test-retention.sh — drives tank-snapshot.sh through the half of itself that a
# kickstart cannot reach.
#
# WHY THIS EXISTS
# A kickstart of local.tank-snapshot on a virgin pool creates one snapshot per
# tier, finds every tier under its keep count, prunes nothing, and exits 0. The
# entire retention half of the script is unexercised, and the run looks like a
# pass. That is the same shape of false confidence as the scrub daemon's green
# kickstart with a live parser bug in a branch the test could not reach — so this
# is the snapshot daemon's tests/scan-parse.
#
# WHAT IT DOES AND DOESN'T PROVE
# It proves BEHAVIOUR: that tiers prune to the right depth, that the survivors
# are the newest, that the pruner cannot see snapshots outside its own prefix,
# that a hold stops a destroy, and that skip-if-unchanged actually skips. It
# runs the script directly rather than through launchd, so it proves nothing
# about the daemon CONTEXT — no TCC, no empty environment, no missing GUI
# session. That is the kickstart's job and neither test substitutes for the
# other.
#
# SAFETY, because this creates and destroys snapshots on the live pool:
#   - Every snapshot it creates is prefixed `test-`, never `auto-`. Production
#     snapshots and this harness cannot collide: the production pruner anchors on
#     ^auto-<tier>-[0-9] and this run anchors on ^test-<tier>-[0-9].
#   - Cleanup only ever destroys names matching @test- or the two named decoys.
#     It cannot reach an auto- snapshot.
#   - It writes a few KB of scratch files under /Volumes/tank/documents/.zfstest
#     and removes them.
# It does exercise the REAL config table in tank-snapshot.sh, deliberately — a
# typo in a keep count is a realistic bug and this is what would catch it.
#
# Usage:  sudo sh tests/snapshot-retention/test-retention.sh
# Run it BEFORE installing to /usr/local/sbin: it tests the repo copy by default.

set -u

ZFS=/usr/local/zfs/bin/zfs
ZPOOL=/usr/local/zfs/bin/zpool
POOL=tank
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${SCRIPT:-$HERE/../../scripts/nas-snapshot/tank-snapshot.sh}

# The dataset the detailed single-dataset assertions run against (ordering,
# holds, written@). Chosen because it is the only one with all three tiers on.
DS=tank/documents

# Every dataset in the config table. The write loop has to touch ALL of them,
# not just $DS: skip-if-unchanged is doing its job, so a dataset that receives
# no writes correctly takes exactly one baseline snapshot and never fills its
# tier. Writing only to $DS would make every other dataset's count assertion
# fail against a perfectly correct daemon.
ALL_DS="tank/my_media tank/documents tank/media"

SCRATCH_DIR=.zfstest
LOG=/tmp/tank-snapshot-test-retention.log

# The keep counts this suite asserts against. They are DUPLICATED from the
# config table in tank-snapshot.sh on purpose: if the two ever disagree, one of
# them is a typo and this suite is what surfaces it. Keeping them in sync by
# hand is the point, not an oversight.
KEEP_MYMEDIA_WEEKLY=8
KEEP_MYMEDIA_MONTHLY=6
KEEP_DOCS_DAILY=7
KEEP_DOCS_WEEKLY=4
KEEP_DOCS_MONTHLY=6
KEEP_MEDIA_WEEKLY=2

# Enough runs to overshoot the deepest tier (my_media weekly, 8) by one. Raising
# this is the only thing to change if a keep count goes above 8.
RUNS=9

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root: sudo sh $0" >&2
	exit 1
fi
if [ ! -f "$SCRIPT" ]; then
	echo "script not found: $SCRIPT" >&2
	exit 1
fi

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
}
check() {
	if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else bad "$1: expected '$3', got '$2'"; fi
}

# Snapshots of $1 in test-tier $2, oldest first, short names.
tier() {
	"$ZFS" list -H -t snapshot -d 1 -o name -s creation "$1" 2>/dev/null |
		sed -n "s|^$1@||p" | grep "^test-$2-[0-9]"
}
count() { tier "$1" "$2" | grep -c . ; }

# Mountpoint of $1, asked of ZFS rather than assumed from the dataset name.
mnt() { "$ZFS" get -H -o value mountpoint "$1" 2>/dev/null; }

# 8 KB of unique data into every dataset. It has to be a real write, or
# skip-if-unchanged correctly refuses the snapshot and no tier ever fills —
# which would make this whole suite silently test nothing.
#
# `zpool sync` IS NOT OPTIONAL, AND `sync(8)` IS NOT A SUBSTITUTE. This cost the
# first run of this suite 11 confusing failures, so it is worth stating exactly.
# `written`/`written@` are ON-DISK accounting: they only move once the writes
# land in a synced transaction group, and ZFS commits a txg on its own schedule
# (zfs_txg_timeout, 5s by default). The POSIX `sync(8)` does not force a txg.
# Measured 2026-08-23 on tank/documents, writing a 256 KB file:
#     written before                 2879488
#     after the write and sync(8)    2879488   <- unchanged
#     after zpool sync tank          3158016   <- +272 KB
# So with only sync(8), six of nine loop iterations correctly read written@ == 0,
# skipped, and the surviving snapshots came out spaced at exactly the 5-second
# txg interval — which is the fingerprint to recognise if this ever recurs.
#
# This is a property of the TEST, not a bug in the daemon: at a daily cadence
# every write it cares about is hours old and long since committed.
churn() {
	for _d in $ALL_DS; do
		_m=$(mnt "$_d")
		[ -d "$_m" ] || { bad "no mountpoint for $_d"; continue; }
		mkdir -p "$_m/$SCRATCH_DIR"
		dd if=/dev/urandom of="$_m/$SCRATCH_DIR/run-$1.bin" bs=1024 count=8 2>/dev/null
	done
	"$ZPOOL" sync "$POOL"
}

# One run of the daemon with test intervals: everything due, every time.
run_daemon() {
	env TANK_SNAPSHOT_PREFIX=test \
		TANK_SNAPSHOT_DAILY_SECS=1 \
		TANK_SNAPSHOT_WEEKLY_SECS=1 \
		TANK_SNAPSHOT_MONTHLY_SECS=1 \
		TANK_SNAPSHOT_SLACK_SECS=0 \
		TANK_SNAPSHOT_HEARTBEAT_SECS=999999999 \
		TANK_SNAPSHOT_LOG="$LOG" \
		TANK_SNAPSHOT_STATE=/tmp/tank-snapshot-test-retention.last \
		TANK_SNAPSHOT_HEARTBEAT=/tmp/tank-snapshot-test-retention.hb \
		sh "$SCRIPT"
}

cleanup() {
	echo
	echo "--- cleanup ---"
	# Release any hold this suite placed, or the destroy below fails.
	"$ZFS" release retention-test "$DS@$held_snap" 2>/dev/null
	# Scoped to @test- and the two decoys by exact name. Nothing here can match
	# an auto- snapshot.
	for s in $("$ZFS" list -H -t snapshot -o name -r tank 2>/dev/null |
		grep -e '@test-' -e '@auto-decoy-donottouch' -e '@manual-keepme'); do
		"$ZFS" destroy "$s" 2>/dev/null && echo "  destroyed $s"
	done
	for _d in $ALL_DS; do
		_m=$(mnt "$_d")
		if [ -n "$_m" ] && [ -d "$_m/$SCRATCH_DIR" ]; then
			rm -rf "$_m/$SCRATCH_DIR"
			echo "  removed $_m/$SCRATCH_DIR"
		fi
	done
	echo
	echo "remaining snapshots on tank (should be production auto-* only, or none):"
	"$ZFS" list -H -t snapshot -o name -r tank 2>/dev/null | sed 's/^/  /'
	echo "  (end)"
}

held_snap=
trap 'cleanup' EXIT INT TERM

rm -f "$LOG"

echo "=== 0. harness canary: written@ must move after a write + zpool sync ==="
# If this fails, NOTHING below it is meaningful. Every tier would sit at its one
# baseline snapshot, no prune would ever be attempted, and the suite would report
# a pile of confusing count failures instead of the single real problem. That is
# precisely what the first run of this suite did on 2026-08-23, so the canary
# exists to turn that into one legible failure at the top.
canary_mnt=$(mnt "$DS")
mkdir -p "$canary_mnt/$SCRATCH_DIR"
"$ZFS" snapshot "$DS@test-canary" || bad "could not create canary snapshot"
w0=$("$ZFS" get -Hp -o value written@test-canary "$DS" 2>/dev/null)
check "written@ is 0 straight after the snapshot" "$w0" "0"
dd if=/dev/urandom of="$canary_mnt/$SCRATCH_DIR/canary.bin" bs=1024 count=64 2>/dev/null
"$ZPOOL" sync "$POOL"
w1=$("$ZFS" get -Hp -o value written@test-canary "$DS" 2>/dev/null)
if [ -n "$w1" ] && [ "$w1" -gt 0 ]; then
	ok "written@ moved to $w1 bytes after a 64 KB write + zpool sync"
else
	bad "written@ is still '$w1' after writing 64 KB and forcing a txg."
	bad "  STOP AND READ THIS. The write is not reaching ZFS's on-disk"
	bad "  accounting, so every assertion below will silently under-test."
fi

echo
echo "=== 1. decoys: the pruner must not see outside its own prefix ==="

# An auto-* name and a hand-made name, both of which the test-prefixed runs
# below must leave completely alone. The auto- decoy is the important one: it
# stands in for a production snapshot, and for todo 3's send base.
"$ZFS" snapshot "$DS@auto-decoy-donottouch" || bad "could not create auto- decoy"
"$ZFS" snapshot "$DS@manual-keepme" || bad "could not create manual decoy"

echo
echo "=== 2. overshoot every tier: $RUNS runs with a write between each ==="

first_daily=
i=1
while [ "$i" -le "$RUNS" ]; do
	churn "$i"
	run_daemon >/dev/null 2>&1
	rc=$?
	[ "$rc" -eq 0 ] || bad "run $i exited $rc (expected 0) — see $LOG"
	# Remember run 1's daily snapshot: with 9 runs and keep 7 it must be gone by
	# the end, and that is the assertion a reversed head/tail in prune() fails.
	# The count assertions alone would pass with the wrong end kept.
	if [ "$i" -eq 1 ]; then
		first_daily=$(tier "$DS" daily | tail -n 1)
	fi
	# Distinct creation timestamps, so `-s creation` has a total order to sort by
	# and "the survivors are the newest" is a meaningful assertion. Also keeps the
	# per-second name stamps unique, since two snapshots in the same second would
	# collide on name and the second would fail as "already exists".
	sleep 1
	i=$((i + 1))
done

echo
echo "=== 3. each tier pruned to its configured depth ==="
check "tank/my_media test-weekly count"  "$(count tank/my_media weekly)"  "$KEEP_MYMEDIA_WEEKLY"
check "tank/my_media test-monthly count" "$(count tank/my_media monthly)" "$KEEP_MYMEDIA_MONTHLY"
check "$DS test-daily count"    "$(count "$DS" daily)"    "$KEEP_DOCS_DAILY"
check "$DS test-weekly count"   "$(count "$DS" weekly)"   "$KEEP_DOCS_WEEKLY"
check "$DS test-monthly count"  "$(count "$DS" monthly)"  "$KEEP_DOCS_MONTHLY"
check "tank/media test-weekly count"   "$(count tank/media weekly)"   "$KEEP_MEDIA_WEEKLY"

# Tiers that are OFF (keep 0) must produce nothing at all. These are the
# assertions that catch a tier switched on by accident, and they matter most on
# my_media, where a daily tier would churn retention on the one dataset whose
# whole point is long-horizon coverage.
check "tank/my_media test-daily count (tier off)" "$(count tank/my_media daily)" "0"
check "tank/media test-daily count (tier off)"    "$(count tank/media daily)"    "0"
check "tank/media test-monthly count (tier off)"  "$(count tank/media monthly)"  "0"

echo
echo "=== 4. the survivors are the NEWEST, not an arbitrary subset ==="
# The last run's stamp must be present in every tier, and the first run's must
# not — the specific way a reversed head/tail would fail is by keeping the
# oldest, which passes the count assertions above unchanged.
newest_daily=$(tier "$DS" daily | tail -n 1)
oldest_daily=$(tier "$DS" daily | head -n 1)
if [ -n "$newest_daily" ] && [ "$newest_daily" != "$oldest_daily" ]; then
	ok "daily tier has an ordered range ($oldest_daily .. $newest_daily)"
else
	bad "daily tier is empty or has one entry — cannot verify ordering"
fi
# Creation time of the newest survivor must be later than that of the oldest.
c_new=$("$ZFS" get -Hp -o value creation "$DS@$newest_daily" 2>/dev/null)
c_old=$("$ZFS" get -Hp -o value creation "$DS@$oldest_daily" 2>/dev/null)
if [ -n "$c_new" ] && [ -n "$c_old" ] && [ "$c_new" -gt "$c_old" ]; then
	ok "newest survivor is newer than oldest survivor"
else
	bad "creation ordering wrong: oldest=$c_old newest=$c_new"
fi
# And the very first snapshot taken must be gone: $RUNS runs, keep 7.
if [ -z "$first_daily" ]; then
	bad "run 1 took no daily snapshot — the loop tested nothing"
elif tier "$DS" daily | grep -qx "$first_daily"; then
	bad "run-1 daily ($first_daily) survived — pruning kept the WRONG END"
else
	ok "run-1 daily ($first_daily) was pruned away"
fi

echo
echo "=== 5. decoys untouched ==="
if "$ZFS" list -H -o name "$DS@auto-decoy-donottouch" >/dev/null 2>&1; then
	ok "auto- decoy survived (pruner is prefix-scoped)"
else
	bad "auto- decoy was DESTROYED — the pruner is not prefix-scoped. This is the"
	bad "  bug that silently breaks todo 3's incremental send base."
fi
if "$ZFS" list -H -o name "$DS@manual-keepme" >/dev/null 2>&1; then
	ok "hand-made decoy survived"
else
	bad "hand-made decoy was DESTROYED"
fi

echo
echo "=== 6. skip-if-unchanged: a run with no write must take nothing ==="
before=$(count "$DS" daily)
sleep 1
run_daemon >/dev/null 2>&1
after=$(count "$DS" daily)
check "daily count after a no-write run" "$after" "$before"
if grep -q 'nothing written since' "$LOG"; then
	ok "log records the skip explicitly"
else
	bad "no 'nothing written since' line in $LOG — the skip branch was not taken,"
	bad "  which means something is writing to the dataset behind our back"
fi

echo
echo "=== 7. a hold stops a destroy, and says so ==="
# Hold the oldest surviving daily, then force another prune. It must survive and
# be logged as HELD rather than counted as a failure.
held_snap=$(tier "$DS" daily | head -n 1)
"$ZFS" hold retention-test "$DS@$held_snap" || bad "could not place hold"
: >"$LOG"
churn hold-probe
sleep 1
run_daemon >/dev/null 2>&1
rc=$?
check "run with a held snapshot exits 0 (a hold is not a failure)" "$rc" "0"
if "$ZFS" list -H -o name "$DS@$held_snap" >/dev/null 2>&1; then
	ok "held snapshot survived the prune"
else
	bad "HELD SNAPSHOT WAS DESTROYED — a hold must stop a destroy"
fi
if grep -q 'HELD, not destroyed' "$LOG"; then
	ok "log records the hold skip"
else
	bad "hold skip not logged — check the destroy error match in prune()"
fi
# A held snapshot pushes the tier one over its depth, which is correct and must
# not be silently absorbed.
check "daily count is keep+1 while one is held" "$(count "$DS" daily)" "$((KEEP_DOCS_DAILY + 1))"

echo
echo "=== 8. written@ is nonzero for a DELETE-ONLY change ==="
# The load-bearing assumption behind skip-if-unchanged. If a week where you only
# DELETED files reported written=0, the daemon would skip precisely the snapshot
# you would most want to have. Measured rather than assumed.
docs_mnt=$(mnt "$DS")
dd if=/dev/urandom of="$docs_mnt/$SCRATCH_DIR/to-be-deleted.bin" bs=1024 count=64 2>/dev/null
"$ZPOOL" sync "$POOL"
"$ZFS" snapshot "$DS@test-delprobe-1" || bad "could not snapshot delete probe"
w_after_snap=$("$ZFS" get -Hp -o value written@test-delprobe-1 "$DS" 2>/dev/null)
check "written@ immediately after snapshot is 0" "$w_after_snap" "0"
rm -f "$docs_mnt/$SCRATCH_DIR/to-be-deleted.bin"
# zpool sync, not sync(8) and not a sleep. The first version of this check read
# written@ two seconds after the unlink, before the txg had committed, and
# reported 0 — which looks exactly like "a delete-only change is invisible to
# the guard" and would have condemned a guard that is in fact fine.
"$ZPOOL" sync "$POOL"
w_after_del=$("$ZFS" get -Hp -o value written@test-delprobe-1 "$DS" 2>/dev/null)
if [ -n "$w_after_del" ] && [ "$w_after_del" -gt 0 ]; then
	ok "written@ after a delete-only change is $w_after_del bytes (> 0)"
else
	bad "written@ after deleting a 64 KB file is '$w_after_del'. IF THIS IS 0, the"
	bad "  skip-if-unchanged guard in tank-snapshot.sh is UNSAFE and must gate on"
	bad "  something else (compare 'referenced', or drop the guard)."
fi

echo
echo "=========================================="
echo "passed $pass, failed $fail"
echo "full daemon log: $LOG"
[ "$fail" -eq 0 ] || exit 1
exit 0
