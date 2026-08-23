#!/bin/sh
#
# tank-backup.sh — replicate `tank` to an offline pool via zfs send/recv.
#
# WHAT THIS IS FOR
# The mirror protects against a drive dying. Snapshots protect against you.
# Neither protects against the enclosure dying, the machine being stolen, or the
# room burning — and a snapshot on a dead pool dies with the pool. This is the
# only thing in the setup that covers those, and it is the only copy that exists
# when the drive is unplugged and elsewhere.
#
# NOT A DAEMON, ON PURPOSE. There is no plist. The destination drive is normally
# disconnected, which is the entire point: a backup that is always attached is an
# online second copy, reachable by the same `rm -rf`, the same ransomware and the
# same power event as the original. So this is run by hand, attended, when the
# drive is plugged in. That also lets the destination pool prompt for its
# passphrase rather than keeping a key on disk.
#
# --- DESIGN ---------------------------------------------------------------
#
# 1. NON-RAW SEND INTO AN INDEPENDENTLY-ENCRYPTED POOL.
#
# `zfs send` without -w decrypts on read and sends plaintext; the destination
# re-encrypts under ITS OWN key. So the two pools share no key material: losing
# one does not compromise the other, and the backup can be read without the
# source's key. The plaintext exists only in a local pipe in memory.
#
# The consequence that decides whether any of this is worth anything: THE
# DESTINATION PASSPHRASE MUST BE RECOVERABLE WITHOUT THIS MACHINE. The scenario
# this drive exists for is the Mac being destroyed or stolen. If the only copy of
# the passphrase lives on the Mac, the backup is unreadable in exactly the case
# it was bought for.
#
# 2. ITS OWN SNAPSHOTS, WITH A PREFIX THE RETENTION PRUNER CANNOT SEE.
#
# This takes `tank@sync-<stamp>` recursively rather than reusing the snapshot
# daemon's tiers. Two reasons. There is no single pool-wide name to use as a base
# — the daemon takes per-dataset, per-tier snapshots with independent names, so
# no consistent "the whole pool at time T" name exists. And replication wants a
# different lifetime than retention: a retention snapshot exists so you can get a
# file back, a sync snapshot exists so the NEXT incremental has a base.
#
# The prefix is load-bearing. tank-snapshot.sh's pruner anchors on
# ^auto-<tier>-[0-9], so `sync-` snapshots are structurally invisible to it and
# it CANNOT reap the incremental base out from under this script. That is a
# stronger guarantee than the `zfs hold` this also takes — the hold is a second
# line of defence against a human with a shell, not the primary one.
#
# Why that matters: `zfs send -i A B` requires A to still exist on BOTH sides. If
# the base is destroyed, the next run cannot do an incremental and degrades to a
# full send of the entire pool over USB — a day-plus once there is real data.
#
# 3. PER-DATASET SENDS, NOT `send -R` FROM THE POOL ROOT.
#
# `-R` from the root would have to receive into `tankbak` itself, which is the
# destination's own encryption root, and `recv -F` against it risks clobbering
# the properties the pool was created with. Sending each dataset into a child of
# `tankbak` keeps the destination root untouched and lets every received dataset
# inherit the destination's encryption cleanly.
#
# The cost is no pool-atomic consistency across datasets. That is not a property
# worth buying here: the datasets are independent, and nothing spans them
# transactionally — no database, no application state.
#
# 4. RESUMABLE RECEIVES.
#
# `recv -s` means an interrupted transfer leaves a resume token on the
# destination instead of throwing the work away. At 13 MB this is irrelevant; at
# 5 TB over USB it is the difference between a retry and a lost day. This script
# checks for a token before doing anything else and resumes it.
#
# To abandon a partial receive instead: zfs recv -A <destination dataset>
#
# 5. `readonly=on` ON THE DESTINATION.
#
# Nothing should ever write to the backup except this script. It is set after
# each successful receive rather than once at create time, because a received
# dataset takes its properties from the stream.
#
# --- WHAT THIS DOES NOT DO -----------------------------------------------
#
# The destination's snapshot history MIRRORS the source's; it does not exceed it.
# `recv -F` rolls the destination forward to match, so a snapshot pruned on
# `tank` goes away here too at the next sync. That leaves one gap, stated so it
# is not mistaken for covered: delete a file, let retention prune the snapshot
# holding it, THEN sync, and both copies have followed you off the cliff.
# Closing it means keeping deeper history on the destination than the source,
# which is a bigger change than a flag. The mitigation for now is that
# `my_media` retention is deep (8 weekly + 6 monthly) precisely so that window
# is months wide.
#
# It also does not verify the restored data. A backup you have never restored
# from is a guess — run the restore test, don't just read the exit code.
#
# --- USAGE ---------------------------------------------------------------
#
#   sudo sh tank-backup.sh              # sync, leave the pool imported
#   sudo sh tank-backup.sh --export     # sync, then export for unplugging
#   sudo sh tank-backup.sh --dry-run    # decide and print, change nothing
#
# Exit codes:
#   0  synced
#   1  refused to start (a pool missing, unhealthy, or key not loaded)
#   2  a send/receive failed — READ THE LOG
#   3  nothing to do (no changes since the last sync)

set -u

ZFS=/usr/local/zfs/bin/zfs
ZPOOL=/usr/local/zfs/bin/zpool

SRC_POOL=tank
DST_POOL=${TANK_BACKUP_DST:-tankbak}

# Datasets to replicate, as bare names under both pools. Everything, currently:
# `media` is re-downloadable but is being kept anyway. If the destination ever
# runs short of space, this is the line to cut — which is the payoff for having
# split my_media off media in the first place.
DATASETS=${TANK_BACKUP_DATASETS:-"my_media media documents"}

# How many sync snapshots to keep on each side. Two, not one: the older one is
# the fallback base if the newest receive turns out to be partial, or if the
# drive was pulled mid-send. One is enough for correctness and leaves no room
# for a bad day.
KEEP_SYNC=${TANK_BACKUP_KEEP_SYNC:-2}

PREFIX=${TANK_BACKUP_PREFIX:-sync}
HOLD_TAG=${TANK_BACKUP_HOLD_TAG:-backup-base}

LOG=${TANK_BACKUP_LOG:-/var/log/tank-backup.log}

DRY_RUN=0
DO_EXPORT=0
for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY_RUN=1 ;;
	--export) DO_EXPORT=1 ;;
	*)
		echo "unknown argument: $arg" >&2
		echo "usage: $0 [--dry-run] [--export]" >&2
		exit 1
		;;
	esac
done

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Unlike the two daemons, this is attended: run() echoes what it is about to do
# so the operator can see the actual send/recv commands, and honours --dry-run.
run() {
	if [ "$DRY_RUN" = 1 ]; then
		log "  DRY RUN: $*"
		return 0
	fi
	"$@"
}

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root: sudo sh $0" >&2
	exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
	log "=== start (pid $$) DRY RUN — deciding only, changing nothing ==="
else
	log "=== start (pid $$) ==="
fi

# ---------------------------------------------------------------------------
# Preflight. Same principle as the daemons: refuse rather than half-do it.
# ---------------------------------------------------------------------------

if ! "$ZPOOL" list -H -o name "$SRC_POOL" >/dev/null 2>&1; then
	log "REFUSED: source pool $SRC_POOL is not imported."
	exit 1
fi

src_health=$("$ZPOOL" list -H -o health "$SRC_POOL" 2>/dev/null)
case "$src_health" in
ONLINE | DEGRADED)
	log "$SRC_POOL health: $src_health"
	;;
*)
	# failmode=wait on tank means reading from a suspended pool blocks in an
	# uninterruptible ioctl that SIGKILL will not free. A send would do exactly
	# that, for hours, holding the destination open. Refuse.
	log "REFUSED: $SRC_POOL health is '${src_health:-<unreadable>}'."
	log "         Not sending: failmode=wait means the read would block forever."
	exit 1
	;;
esac

# The destination is normally exported, so importing it is the expected path
# rather than an error. It is NOT auto-imported at boot: stock OpenZFS
# auto-import is off via /etc/zfs/noautoimport and tank-boot-unlock.sh imports
# `tank` by name only.
if ! "$ZPOOL" list -H -o name "$DST_POOL" >/dev/null 2>&1; then
	log "$DST_POOL not imported — importing"
	if ! run "$ZPOOL" import "$DST_POOL"; then
		log "REFUSED: could not import $DST_POOL. Is the drive plugged in?"
		log "         Available pools: $("$ZPOOL" import 2>&1 | awk '/pool:/{print $2}' | tr '\n' ' ')"
		exit 1
	fi
fi

dst_health=$("$ZPOOL" list -H -o health "$DST_POOL" 2>/dev/null)
if [ "$dst_health" != "ONLINE" ]; then
	# Stricter than the source deliberately. A DEGRADED source is still worth
	# backing up; a DEGRADED destination is not worth writing a backup onto.
	log "REFUSED: $DST_POOL health is '${dst_health:-<unreadable>}', not ONLINE."
	exit 1
fi
log "$DST_POOL health: ONLINE"

# keylocation=prompt, so this asks interactively. That is why the script is
# attended and has no plist.
keystatus=$("$ZFS" get -H -o value keystatus "$DST_POOL" 2>/dev/null)
if [ "$keystatus" != "available" ]; then
	log "$DST_POOL key not loaded — prompting"
	if ! run "$ZFS" load-key "$DST_POOL"; then
		log "REFUSED: could not load the key for $DST_POOL."
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Sync snapshots of $1, oldest first, short names. Sorted by creation rather
# than by name: the stamp sorts chronologically today, but creation order is the
# truth and survives a clock change.
sync_snaps() {
	"$ZFS" list -H -t snapshot -d 1 -o name -s creation "$1" 2>/dev/null |
		sed -n "s|^$1@||p" | grep "^$PREFIX-[0-9]"
}

# Newest sync snapshot that exists on BOTH sides — the only valid incremental
# base. Asking both rather than assuming the last run succeeded is the point:
# `zfs send -i` fails outright if the base is missing on the destination, and a
# half-finished previous run is exactly when that happens.
common_base() {
	_src=$1
	_dst=$2
	_newest=
	for _s in $(sync_snaps "$_src"); do
		if "$ZFS" list -H -o name "$_dst@$_s" >/dev/null 2>&1; then
			_newest=$_s
		fi
	done
	echo "$_newest"
}

# Keep the newest $KEEP_SYNC, destroy older ones. Scoped to the sync prefix, so
# it cannot touch a retention snapshot or anything made by hand.
prune_sync() {
	_ds=$1
	_all=$(sync_snaps "$_ds")
	_n=$(printf '%s' "$_all" | grep -c .)
	[ -z "$_n" ] && _n=0
	[ "$_n" -le "$KEEP_SYNC" ] && return 0

	for _s in $(printf '%s\n' "$_all" | head -n $((_n - KEEP_SYNC))); do
		# Release our own hold first, if this is a source dataset carrying one.
		# Holds exist to stop an accident, not to stop this script.
		"$ZFS" holds -H "$_ds@$_s" 2>/dev/null | grep -q "$HOLD_TAG" &&
			run "$ZFS" release "$HOLD_TAG" "$_ds@$_s" 2>/dev/null
		if run "$ZFS" destroy "$_ds@$_s"; then
			log "  pruned $_ds@$_s"
		else
			log "  could not prune $_ds@$_s (held elsewhere? see: zfs holds $_ds@$_s)"
		fi
	done
}

# ---------------------------------------------------------------------------
# 0. Finish any interrupted receive before starting new work. A destination
#    holding a resume token will reject a fresh send, and resuming is both
#    cheaper and the only way to not lose the bytes already transferred.
# ---------------------------------------------------------------------------

for name in $DATASETS; do
	dst="$DST_POOL/$name"
	"$ZFS" list -H -o name "$dst" >/dev/null 2>&1 || continue
	token=$("$ZFS" get -H -o value receive_resume_token "$dst" 2>/dev/null)
	case "$token" in
	'' | '-') continue ;;
	esac
	log "$dst has an interrupted receive — resuming"
	if [ "$DRY_RUN" = 1 ]; then
		log "  DRY RUN: would resume with zfs send -t <token> | zfs recv -s $dst"
		continue
	fi
	if "$ZFS" send -t "$token" | "$ZFS" recv -s "$dst"; then
		log "  resume completed"
	else
		log "FAIL: resume of $dst failed. To abandon it instead: zfs recv -A $dst"
		exit 2
	fi
done

# ---------------------------------------------------------------------------
# 1. One recursive snapshot, so every dataset's send refers to the same instant
#    even though the sends themselves are independent.
# ---------------------------------------------------------------------------

STAMP=$(date '+%Y-%m-%d-%H%M%S')
NEW="$PREFIX-$STAMP"

# Skip the whole run if nothing changed anywhere since the last sync. `written@`
# is on-disk accounting and does not move until the writes land in a synced
# transaction group, so force one first — POSIX sync(8) does NOT do this, which
# is measurable and cost a test suite eleven failures once.
#
# Deliberately NOT wrapped in run(): committing a pending txg changes no user
# data, and skipping it under --dry-run would make the dry run read stale
# `written@` values and report the wrong decision.
"$ZPOOL" sync "$SRC_POOL"

changed=0
for name in $DATASETS; do
	src="$SRC_POOL/$name"
	base=$(common_base "$src" "$DST_POOL/$name")
	if [ -z "$base" ]; then
		changed=1
		break
	fi
	w=$("$ZFS" get -Hp -o value "written@$base" "$src" 2>/dev/null)
	case "$w" in
	0) ;;
	*)
		changed=1
		break
		;;
	esac
done

if [ "$changed" -eq 0 ]; then
	log "nothing written on any dataset since the last sync — nothing to do"
	log "=== done (exit 3) ==="
	exit 3
fi

log "snapshotting $SRC_POOL@$NEW recursively"
if ! run "$ZFS" snapshot -r "$SRC_POOL@$NEW"; then
	log "FAIL: could not create $SRC_POOL@$NEW"
	exit 2
fi

# ---------------------------------------------------------------------------
# 2. Send each dataset.
# ---------------------------------------------------------------------------

failed=0
sent=0

for name in $DATASETS; do
	src="$SRC_POOL/$name"
	dst="$DST_POOL/$name"

	if ! "$ZFS" list -H -o name "$src" >/dev/null 2>&1; then
		log "$src does not exist — skipping"
		continue
	fi

	base=$(common_base "$src" "$dst")

	if [ -z "$base" ]; then
		# No shared snapshot, so no incremental is possible. Either this is the
		# first ever sync, or the chain was broken (base pruned on one side, drive
		# replaced, destination rebuilt). Either way the only option is a full
		# send, and at real data volumes that is a very long operation — so say so
		# rather than silently starting a day-long transfer.
		log "$src -> $dst: FULL send of @$NEW (no common snapshot)"
		log "         This is the expensive path. Expect hours at real volumes."
		if run sh -c "'$ZFS' send '$src@$NEW' | '$ZFS' recv -F -u -s '$dst'"; then
			log "  full send OK"
			sent=$((sent + 1))
		else
			log "FAIL: full send of $src failed"
			log "      A partial receive may be resumable — rerun this script."
			log "      To abandon it instead: zfs recv -A $dst"
			failed=$((failed + 1))
			continue
		fi
	else
		log "$src -> $dst: incremental @$base -> @$NEW"
		if run sh -c "'$ZFS' send -i '@$base' '$src@$NEW' | '$ZFS' recv -F -u -s '$dst'"; then
			log "  incremental OK"
			sent=$((sent + 1))
		else
			log "FAIL: incremental send of $src failed"
			log "      Rerun to resume; zfs recv -A $dst to abandon the partial."
			failed=$((failed + 1))
			continue
		fi
	fi

	# Hold the new base on the source. The `sync-` prefix already makes it
	# invisible to tank-snapshot.sh's pruner, so this is defence against a human
	# with a shell rather than against the daemon.
	run "$ZFS" hold "$HOLD_TAG" "$src@$NEW" 2>/dev/null

	# Nothing but this script should ever write to the destination. Set after the
	# receive, because a received dataset takes its properties from the stream.
	run "$ZFS" set readonly=on "$dst"
done

# ---------------------------------------------------------------------------
# 3. Prune both sides, then report.
# ---------------------------------------------------------------------------

if [ "$failed" -eq 0 ]; then
	for name in $DATASETS; do
		prune_sync "$SRC_POOL/$name"
		prune_sync "$DST_POOL/$name"
	done
	# The recursive snapshot also made one on the pool root, which is never sent
	# anywhere and would otherwise accumulate forever.
	prune_sync "$SRC_POOL"
else
	# Pruning while something failed could destroy the base the retry needs.
	log "skipping prune: $failed dataset(s) failed, keeping every base available"
fi

log "sent $sent, failed $failed"
"$ZFS" list -o name,used,avail,readonly -r "$DST_POOL" 2>&1 | tee -a "$LOG"

if [ "$failed" -gt 0 ]; then
	log "=== done (exit 2) — READ THE FAILURES ABOVE ==="
	exit 2
fi

if [ "$DO_EXPORT" = 1 ]; then
	# Export before unplugging. Yanking an imported pool is the bridge-fault
	# scenario from the drive-pull test, on purpose and for no reason.
	log "exporting $DST_POOL — safe to unplug once this returns"
	if ! run "$ZPOOL" export "$DST_POOL"; then
		log "WARNING: export failed. DO NOT UNPLUG. Something is holding the pool:"
		log "         check for open files under the mountpoint, then retry."
		exit 2
	fi
	log "exported"
else
	log "$DST_POOL left imported. Export before unplugging:"
	log "  sudo $ZPOOL export $DST_POOL"
fi

log "=== done (exit 0) ==="
exit 0
