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
# re-encrypts under ITS OWN key. So the two pools share no key MATERIAL — the
# destination's master key is generated on the destination and never leaves it,
# and `encryptionroot` on a received dataset reads as the destination pool. The
# backup is therefore readable without the source's key, and the plaintext exists
# only in a local pipe in memory.
#
# BE PRECISE ABOUT WHAT THAT DOES AND DOES NOT BUY, because an earlier version of
# this comment overclaimed it. It said "losing one does not compromise the
# other", which was true of the key material and is NOT true of the secret: as of
# 2026-09-13 the destination is deliberately created with THE SAME PASSPHRASE as
# `tank` (see tankbak-create.sh, DESIGN 3). One passphrase to remember, and
# therefore one passphrase to keep recoverable — at the cost that a leaked
# passphrase now opens both copies. Independent master keys still mean a
# corrupted or brute-forced pool does not imply anything about the other one, and
# that `zfs change-key` on either side does not touch the other. Independent
# failure against a leaked secret is the part that was traded away, knowingly.
#
# It is a small trade here: tank's passphrase already sits in a file on an
# internal SSD that is not yet FileVault-encrypted, so it was never the strong
# link in the source's chain either.
#
# The consequence that decides whether any of this is worth anything: THE
# DESTINATION PASSPHRASE MUST BE RECOVERABLE WITHOUT THIS MACHINE. The scenario
# this drive exists for is the Mac being destroyed or stolen. If the only copy of
# the passphrase lives on the Mac, the backup is unreadable in exactly the case
# it was bought for. Sharing the passphrase with `tank` does not relax that
# requirement — it concentrates it into a single secret.
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
# IT DOES NOT BACK UP SNAPSHOT HISTORY. THE DESTINATION IS A CURRENT-STATE
# MIRROR, NOT AN ARCHIVE.
#
# This comment used to claim the destination's history "MIRRORS the source's".
# It does not, and the correction matters in exactly the scenario the drive
# exists for. A full send here is `zfs send <ds>@sync-<stamp>` — a single
# snapshot — and an incremental is `send -i`, which carries the delta between
# two snapshots and NO intermediate ones. `-I` would include them, `-R` would
# too; neither is used. So no `auto-weekly` or `auto-monthly` snapshot has ever
# reached the destination, and none will.
#
# The KEEP_SYNC `sync-` snapshots that do land there are not history either:
# the older one exists as a fallback incremental base if the newest receive
# turns out to be partial. That is a replication mechanism, not a restore point.
#
# Measured 2026-09-14: tank used 1.23T, tankbak 864G. The 397G gap was my_media
# blocks held only by @auto-weekly-2026-09-07-020002 — bytes that had been moved
# to `media` and so were already replicated under their new home. The general
# case is not so lucky.
#
# So: lose `tank` and you recover the last synced state, with every earlier
# version gone. Deep retention on my_media protects against a mistaken `rm`
# while tank is alive and does nothing for the offsite copy. Snapshots and
# backups cover different failures; this is the seam between them.
#
# Accepted deliberately on 2026-09-14 rather than closed. Closing it means
# `send -I` plus a destination-side retention policy that does not exist, or
# re-sending full history — 821G for my_media alone. Neither buys much against
# enclosure death, theft or fire, which is what this drive is for.
#
# It also does not verify the restored data. A backup you have never restored
# from is a guess — run the restore test, don't just read the exit code.
#
# --- USAGE ---------------------------------------------------------------
#
# THIS DOES NOT CREATE THE DESTINATION POOL. On a fresh drive, run
# tankbak-create.sh first — it owns every decision that is permanent for the life
# of the pool (ashift, cipher, encryption root, key format, key location) and
# refuses to touch anything that is internal, virtual, or a member of an imported
# pool. This script only ever replicates into a pool that already exists.
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

# Where to look for the destination pool's devices. THIS IS NOT OPTIONAL AND IT
# IS NOT THE DEFAULT.
#
# A bare `zpool import tankbak` searches the default path, which resolves devices
# through by-id — GPT UUIDs like media-F8800B76-94DD-3843-BB21-67242CBF1E3D. On
# 2026-08-23 that failed after an ordinary unplug/replug cycle:
#     cannot import 'tankbak': one or more devices is currently unavailable
# after burning 2m15s, while a plain scan simultaneously reported the pool as
# ONLINE and importable. Adding -d /var/run/disk/by-serial imported it instantly.
#
# This is the same lesson the pool build already recorded for `tank` — import by
# by-serial, never by-id — and tank-boot-unlock.sh passes explicit by-serial
# device paths for precisely this reason. It just never got carried into this
# script. It is a property of the naming layer, not of the drive, so it would
# have bitten the real backup drive exactly the same way.
DEV_DIR=${TANK_BACKUP_DEV_DIR:-/var/run/disk/by-serial}

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

# Honour --export on EVERY exit path that got far enough to import the pool.
#
# WHY THIS IS A FUNCTION AND NOT A BLOCK AT THE BOTTOM: it used to be a block at
# the bottom, and five exit paths — including the ordinary nothing-to-send one —
# returned before reaching it. So `--export` would import the drive, do its work,
# and leave it imported, after the operator had explicitly asked for it to be
# ready to unplug. That is the single state you must not unplug from: ZFS holds
# the pool while the device disappears, which is the drive-pull test's failure
# reproduced deliberately and for no reason.
#
# Exporting is safe on failure paths too. ZFS is transactional and a resume token
# is durable, so a partial receive survives an export and can be resumed at the
# next attach. Leaving it imported would only be more convenient for an immediate
# retry, and that is not worth the risk of an unplug.
maybe_export() {
	if [ "$DO_EXPORT" != 1 ]; then
		log "$DST_POOL left imported. Export before unplugging:"
		log "  sudo $ZPOOL export $DST_POOL"
		return 0
	fi
	log "exporting $DST_POOL — safe to unplug once this returns"
	if run "$ZPOOL" export "$DST_POOL"; then
		log "exported"
		return 0
	fi
	log "WARNING: export failed. DO NOT UNPLUG. Something is holding the pool:"
	log "         check for open files under the mountpoint, then retry:"
	log "         sudo $ZPOOL export $DST_POOL"
	return 1
}

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
	log "$DST_POOL not imported — importing from $DEV_DIR"
	if ! run "$ZPOOL" import -d "$DEV_DIR" "$DST_POOL"; then
		log "REFUSED: could not import $DST_POOL from $DEV_DIR."
		# Print the WHOLE scan, not a grep of it. An earlier version reduced this
		# to a list of pool names, which threw away the config block naming the
		# unavailable device and its state — i.e. the only part that explains the
		# failure. The diagnostic then had to be re-run by hand anyway.
		log "         Scan of $DEV_DIR follows:"
		"$ZPOOL" import -d "$DEV_DIR" 2>&1 | sed 's/^/         /' | tee -a "$LOG"
		log "         Devices present in $DEV_DIR:"
		ls "$DEV_DIR" 2>&1 | sed 's/^/         /' | tee -a "$LOG"
		log "         If the drive is plugged in and the pool shows as ONLINE above,"
		log "         try a different search dir: zpool import -d /dev $DST_POOL"
		log "         If the scan lists NO pool at all and this is a new drive,"
		log "         the pool does not exist yet — this script does not create it:"
		log "           sudo sh scripts/nas-backup/tankbak-create.sh --list"
		exit 1
	fi
fi

dst_health=$("$ZPOOL" list -H -o health "$DST_POOL" 2>/dev/null)
if [ "$dst_health" != "ONLINE" ]; then
	# Stricter than the source deliberately. A DEGRADED source is still worth
	# backing up; a DEGRADED destination is not worth writing a backup onto.
	log "REFUSED: $DST_POOL health is '${dst_health:-<unreadable>}', not ONLINE."
	maybe_export
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
		maybe_export
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

# Make every destination dataset readonly=on, and PROVE it rather than assume.
# Returns the number that could not be set.
#
# WHY THIS UNMOUNTS FIRST, AND WHAT IT IS *NOT* FOR:
#
# `zfs get readonly` on a MOUNTED dataset can report the mount's state rather
# than the stored property. Measured 2026-08-23: the third sync's epilogue
# printed readonly=off for all three datasets, because the restore test had
# mounted them and left them that way. The stored property was `on` with source
# `local` the entire time — confirmed after the next export/import, with nothing
# having set it in between. The `zfs set` had worked. Only the reading misled.
#
# So the alarming version of this — "the backup silently became writable" — was
# wrong, and the property was never lost. What IS true is narrower: while a
# dataset is mounted read-write, writes through that existing mount succeed until
# it is remounted. Unmounting first closes that gap by making the effective state
# match the property immediately.
#
# Reading the property back afterwards is cheap insurance, not a fix for an
# observed failure. Worth keeping anyway: `zfs set` can genuinely fail, and the
# old code discarded its exit status, so a real failure would have been silent.
#
# Nothing should be mounted here in normal operation — recv -u leaves the
# datasets alone, and the restore test now unmounts what it mounts.
enforce_readonly() {
	_bad=0
	for _name in $DATASETS; do
		_d="$DST_POOL/$_name"
		"$ZFS" list -H -o name "$_d" >/dev/null 2>&1 || continue

		if [ "$("$ZFS" get -H -o value mounted "$_d" 2>/dev/null)" = "yes" ]; then
			log "  $_d was mounted — unmounting before setting readonly"
			run "$ZFS" unmount "$_d" 2>/dev/null ||
				log "  could not unmount $_d; the readonly set may fail"
		fi

		[ "$("$ZFS" get -H -o value readonly "$_d" 2>/dev/null)" = "on" ] && continue

		run "$ZFS" set readonly=on "$_d" 2>/dev/null
		[ "$DRY_RUN" = 1 ] && continue

		_ro=$("$ZFS" get -H -o value readonly "$_d" 2>/dev/null)
		if [ "$_ro" != "on" ]; then
			log "FAIL: $_d reads readonly='$_ro' and could not be set to on."
			log "      If it is still mounted, this may be the mount's state rather"
			log "      than the stored property — check both, they can disagree:"
			log "      zfs get -o all mounted,readonly $_d"
			log "      A 'local' source of 'on' means the property is fine and only"
			log "      the live mount is writable. Look for a stray mount from"
			log "      tests/backup-restore/ before assuming the backup is exposed."
			_bad=$((_bad + 1))
		else
			log "  $_d readonly=on"
		fi
	done
	return "$_bad"
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
		log "  DRY RUN: would resume with zfs send -t <token> | zfs recv -u -s $dst"
		continue
	fi
	# A resume cannot use -F, so a destination dirtied since its last snapshot
	# has to be rolled back by hand or the resume is rejected outright with
	# "destination has been modified since most recent snapshot".
	#
	# This is not hypothetical and it is the same 2026-09-14 incident as below:
	# the resumed dataset mounted itself, macOS spent 1h46m writing 28 MB of
	# Spotlight and .fseventsd metadata into it, and the next run's resume was
	# refused. Two failures from one missing flag — first the receive was
	# blocked, then the token was invalidated.
	#
	# Rolling back is safe BY DEFINITION here. The destination is readonly=on
	# and is a pure replica; anything written to it locally is either macOS
	# noise or a mistake, and in both cases the source is authoritative. This is
	# exactly what the -F on every other receive in this script already does. It
	# is done explicitly rather than left to the operator because the failure
	# surfaces hours into a run, and the recovery is two commands nobody
	# remembers at 3am.
	dirty=$("$ZFS" get -Hp -o value written "$dst" 2>/dev/null)
	case "${dirty:-0}" in
	'' | 0 | '-') ;;
	*)
		newest=$("$ZFS" list -H -t snapshot -d 1 -o name -s creation "$dst" 2>/dev/null | tail -1)
		if [ -n "$newest" ]; then
			log "  $dst has $dirty bytes written since $newest — rolling back"
			log "  (destination is readonly=on and a pure replica, so this is noise)"
			# Not piped through tee: a pipeline's status is the LAST command's,
			# so `| tee` would report tee's success and hide a failed rollback —
			# and the resume immediately below would then fail for a reason the
			# log had just claimed was handled.
			if run "$ZFS" rollback "$newest"; then
				log "  rolled back to $newest"
			else
				log "  WARNING: rollback of $dst to $newest failed; the resume"
				log "           below will probably be refused. Check for a"
				log "           snapshot newer than the resume base, or a clone."
			fi
		else
			log "  WARNING: $dst has $dirty bytes written but no snapshot to roll"
			log "           back to. The resume below will probably be refused."
		fi
		;;
	esac

	# -u IS LOAD-BEARING AND WAS MISSING UNTIL 2026-09-14.
	#
	# Every other receive in this script passes -u; this one did not, and the
	# asymmetry was invisible until a resume actually ran against real data.
	# Without it the resumed dataset is MOUNTED the moment the receive finishes,
	# and a mounted dataset cannot be received into — so the very next send in
	# the same run dies with:
	#     cannot receive incremental stream: dataset is busy
	# Measured: the 2026-09-14 run resumed 424 GB of my_media over 1h31m, then
	# failed its 2.4 MB follow-up incremental three seconds later for exactly
	# this reason, while media and documents sailed through.
	#
	# Same failure the restore test's README already records from 2026-08-23,
	# reached by a different route: anything that leaves the destination mounted
	# breaks the next receive. Nothing should ever mount here.
	if "$ZFS" send -t "$token" | "$ZFS" recv -u -s "$dst"; then
		log "  resume completed"
	else
		log "FAIL: resume of $dst failed."
		log "      If it said 'destination has been modified since most recent"
		log "      snapshot', something wrote to the backup. Abandon the partial"
		log "      and roll the destination back to its snapshot, then rerun:"
		log "        sudo $ZFS recv -A $dst"
		log "        sudo $ZFS rollback \$($ZFS list -H -t snapshot -d 1 -o name \\"
		log "          -s creation $dst | tail -1)"
		log "      Neither destroys replicated data — the snapshot holds it."
		log "      To abandon the partial receive and nothing else: zfs recv -A $dst"
		maybe_export
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
	# Still enforce readonly before leaving. Otherwise a destination that drifted
	# writable would stay that way indefinitely: every subsequent run would also
	# find nothing to send and exit here, never reaching the check below.
	enforce_readonly
	ro_bad=$?
	maybe_export || ro_bad=$((ro_bad + 1))
	if [ "$ro_bad" -gt 0 ]; then
		log "=== done (exit 2) ==="
		exit 2
	fi
	log "=== done (exit 3) ==="
	exit 3
fi

log "snapshotting $SRC_POOL@$NEW recursively"
if ! run "$ZFS" snapshot -r "$SRC_POOL@$NEW"; then
	log "FAIL: could not create $SRC_POOL@$NEW"
	maybe_export
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

	# A mounted destination cannot be received into — `zfs recv` reports
	# "dataset is busy" and the send dies. So unmount first rather than trusting
	# that nothing mounted it.
	#
	# This is belt to the -u braces on every receive above, and it is worth
	# having both: -u stops THIS script mounting anything, while this handles a
	# mount that arrived some other way. Both routes have actually happened —
	# the restore test left mounts behind on 2026-08-23, and the resume path
	# mounted my_media itself on 2026-09-14 by omitting -u. A third route is
	# macOS auto-mounting a volume that appears while Finder is watching.
	#
	# Deliberately NOT a failure if the unmount does not take: the send below
	# will fail loudly and specifically on its own, and refusing here would turn
	# a recoverable condition into a refused run.
	if [ "$("$ZFS" list -H -o name "$dst" 2>/dev/null)" = "$dst" ] &&
		[ "$("$ZFS" get -H -o value mounted "$dst" 2>/dev/null)" = "yes" ]; then
		log "$dst is mounted — unmounting before receiving into it"
		run "$ZFS" unmount "$dst" 2>/dev/null ||
			log "  WARNING: could not unmount $dst; the receive will likely fail"
	fi

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
done

# Nothing but this script should ever write to the destination. Done here, once,
# rather than inside the loop, so the check covers every dataset even if one
# send was skipped — and so a failure is counted rather than swallowed.
#
# Captured into a variable rather than tested with `if !`, because `$?` inside
# the branch of an `if !` is not reliably the function's own status.
enforce_readonly
ro_bad=$?
failed=$((failed + ro_bad))

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
	maybe_export
	log "=== done (exit 2) — READ THE FAILURES ABOVE ==="
	exit 2
fi

maybe_export || {
	log "=== done (exit 2) — synced, but the export failed ==="
	exit 2
}

log "=== done (exit 0) ==="
exit 0
