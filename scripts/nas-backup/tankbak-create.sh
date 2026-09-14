#!/bin/sh
#
# tankbak-create.sh — create the offline backup pool on a fresh drive.
#
# WHY THIS IS A SCRIPT AND NOT A README SNIPPET
#
# tank-backup.sh assumes the destination pool already exists — it imports it,
# replicates into it, and refuses if it cannot. The pool it was developed against
# was created by hand with a command nobody wrote down, on a stand-in device that
# is now gone (see HISTORY). So the one step with the least room for a do-over was
# the one step with no record of how it was done.
#
# Least room for a do-over, because every decision below is permanent for the life
# of the pool. `ashift` cannot be changed. The encryption root, the cipher and the
# key format cannot be changed. Getting one of them wrong is not a property edit
# later, it is destroying the pool and re-sending every byte over USB.
#
# It is also the only script here that can destroy data that is not its own. So it
# is mostly refusals, and the one thing it does is printed in full before it runs.
#
# --- DESIGN ---------------------------------------------------------------
#
# 1. THE TARGET IS NAMED EXPLICITLY, BY SERIAL. THERE IS NO AUTO-DETECT.
#
# "The external drive that isn't part of tank" is a tempting way to find the
# target and a terrible one: it is also the description of somebody's Time
# Machine disk, or a camera card, on the one day it happens to be plugged in.
# The operator names the drive and types the name back to confirm.
#
# by-serial for the same reason as everywhere else in this repo: device nodes
# move when a USB bridge re-enumerates, and `zpool status` on a by-serial vdev
# prints a name that maps to a physical object you can hold.
#
# 2. WHAT IT REFUSES, AND WHY EACH ONE IS WORTH A CHECK
#
#   - not root, or no tty          the passphrase prompt needs one; fail early
#   - target is an internal device a backup drive is external, always. This is a
#                                  much stronger guard than trying to identify
#                                  the boot disk, which on APFS means chasing a
#                                  synthesized container back to its physical
#                                  store — `/` reports disk3, the data is on
#                                  disk0, and a check on the wrong one passes
#                                  while proving nothing.
#   - target is a virtual device   blocks the leftover 8 TB disk image that has
#                                  been attached since the pool build, which
#                                  reports itself as media name "tank".
#   - target is in an imported pool the mirror. This is the one that matters.
#   - target is smaller than tank's allocated bytes
#   - a pool of this name is already imported
#
# 2a. SHARING TANK'S ENCLOSURE IS DETECTED AND REPORTED. IT IS NOT REFUSED.
#
# A spare bay in the Orico is a perfectly reasonable home for this drive while it
# is being written, and this script's first version refused it. That was wrong,
# and it is worth recording why, because the wrong reasoning was seductive:
#
#   - The drive joins no vdev. `tank`'s topology does not change, and
#     `zpool create` touches only the device named on the command line. There is
#     no RAID interaction to worry about, which was the thing actually asked.
#   - "A backup that is always attached is an online second copy" is the README's
#     argument and it is a good one, but it is about a drive that LIVES in the
#     enclosure. A drive that is in a bay for the duration of a sync and in a
#     drawer the rest of the month is an offline backup by any definition.
#   - The drive-pull test's finding — one pull dropped both LUNs — was about an
#     IN-USE MIRROR MEMBER of an IMPORTED pool. Applying it to an exported,
#     non-member third disk was an extrapolation presented as evidence.
#
# WHAT IS ACTUALLY TRUE, AND IT IS ABOUT REMOVAL, NOT CREATION: on a single-bridge
# enclosure a device-removal event can make the bridge re-enumerate, and if that
# drops tank's LUNs too then tank suspends. failmode=wait means anything touching
# it — Jellyfin included — blocks in an ioctl that SIGKILL cannot free. Recovery
# is `zpool clear tank` once the devices are back; it is annoying rather than
# dangerous, since ZFS is transactional.
#
# So the risk lives entirely at unplug time, which is why refusing at CREATE time
# was the wrong place for the check. It is reported here, and the removal
# procedure is printed in the next-steps block below and in the README.
#
# The detection is exact rather than a guess. `diskutil info -plist` exposes
# DeviceTreePath, the USB port path, and measured 2026-09-13 both mirror members
# report an IDENTICAL one:
#   IODeviceTree:/arm-io@.../pcie-xhci-ss-port1@08100000/usb3-hub-port3@08130000
# because the enclosure presents two LUNs behind a single bridge on a single
# port. An exact string match against the source pool's members is therefore an
# exact same-enclosure test — and a far better one than pattern-matching the
# shared `-20170331000C3` suffix in the by-serial names, which is a convention of
# that particular bridge rather than a property of anything.
#
# 3. THE ENCRYPTION DECISION, IN FULL.
#
# The pool is its OWN encryption root, with keyformat=passphrase, using THE SAME
# PASSPHRASE AS `tank`. Those two halves are independent and both deliberate:
#
#   Own encryption root  — the master key is generated here and never leaves.
#     tank-backup.sh sends non-raw, so the destination re-encrypts under its own
#     key. `encryptionroot` on a received dataset reads `tankbak`, not `tank`.
#     This keeps the send on the path that is already restore-tested; raw send
#     (-w) of encrypted datasets is the historically buggiest corner of native
#     ZFS encryption, and it would additionally make `zfs change-key` on tank
#     break every future incremental.
#
#   Same passphrase — one secret to remember, and therefore one secret to keep
#     recoverable. Be honest about what this costs: the two pools share no key
#     MATERIAL, but they no longer fail independently against a leaked
#     PASSPHRASE. That is the accepted trade. It is a small one here because
#     tank's passphrase already sits in a file on an internal SSD that is not
#     yet FileVault-encrypted, so the passphrase is not the strong link in the
#     source's chain either.
#
# THE PART THAT DECIDES WHETHER ANY OF THIS IS WORTH ANYTHING:
# THE PASSPHRASE MUST BE RECOVERABLE WITHOUT THIS MACHINE. The scenario this
# drive exists for is the Mac being destroyed or stolen. A passphrase whose only
# copy is the key file on the Mac makes the backup unreadable in exactly the case
# it was bought for. Sharing it with tank does not change that requirement — it
# concentrates it.
#
# 4. keylocation=prompt. NO KEY FOR THIS DRIVE EXISTS ON THE MAC.
#
# Not file:///etc/zfs/keys/... like tank. tank's key is on disk because it has
# to be: a pool that must come back after an unattended reboot cannot prompt.
# This pool has the opposite requirement — it is imported by hand, attended,
# a few times a month — so there is no reason to leave anything on the Mac that
# unlocks it. Stealing the Mac must not also hand over the backup.
#
# The consequence is the feature: this pool CANNOT be synced unattended. If a
# scheduled backup is ever wanted, that is a decision to re-make here, not a
# flag to add to tank-backup.sh.
#
# 4a. TWO WAYS TO SUPPLY THE PASSPHRASE, AND WHY THE INDIRECT ONE IS SAFER.
#
# The end state is always keylocation=prompt. How the passphrase gets in at
# CREATE time is a separate question, because `keyformat` is immutable but
# `keylocation` is not — it can be changed on an encryption root at any time.
#
#   default        `zpool create` prompts twice and you type it. Proves you can
#                  reproduce the passphrase by hand, which is the thing a restore
#                  will demand. Fine for something human-memorable.
#
#   --key-from-tank  create with keylocation pointed at TANK'S OWN KEY FILE, so
#                  the passphrase is read rather than typed, then immediately
#                  `zfs set keylocation=prompt`. The passphrase is byte-identical
#                  to tank's BY CONSTRUCTION rather than by luck.
#
# Use the flag when tank's passphrase is a long random string. Retyping 44
# characters of base64 into a blind prompt, twice, is pure downside: a typo you
# make consistently produces a pool locked behind a secret you do not have, and
# `keyformat` cannot be changed afterwards to get out of it.
#
# It does not weaken the result. The file is read once, during creation, by root,
# on the machine that already holds it — and the pool it produces has
# keylocation=prompt exactly as if you had typed it. Nothing on this Mac points
# at the backup afterwards, which is the property DESIGN 4 is about.
#
# What it does skip is the rehearsal: you never prove you can produce the
# passphrase from memory or from the password store. Do that in the restore test,
# which prompts for it anyway, and which is the right place for that failure to
# surface.
#
# 5. STILL, VERIFY THE PASSPHRASE REALLY IS TANK'S.
#
# `zpool create` asks twice, so it catches a typo. It cannot catch the operator
# confidently entering a DIFFERENT passphrase twice — and the pool would then be
# fine, importable, and locked behind a secret nobody has written down. You would
# find out at the restore, which is the worst available moment.
#
# So after creating, this unloads the key and reloads it with `-L` pointed at
# tank's key file. `-L` overrides the locator for one invocation without touching
# the stored property. If that load succeeds, the passphrase provably matches
# tank's. If it fails, the pool is still good but its passphrase is something
# else, and the script says so loudly rather than leaving you to assume.
#
# Skip with --no-key-check if tank's passphrase is deliberately NOT being reused.
#
# 6. cachefile=none.
#
# An offline drive must stay offline. Recording this pool in /etc/zfs/zpool.cache
# would make it a candidate for import at boot by anything that reads the cache —
# and "the backup was mounted the whole time" is how a backup stops being one.
# It costs nothing: tank-backup.sh imports with an explicit -d, which scans
# labels and never consults the cache.
#
# 7. failmode=continue, where tank gets `wait`.
#
# On tank, `wait` is right: hang rather than return errors for a pool holding the
# only copy. Here it is exactly wrong. A yanked backup drive should fail the
# receive so it can be retried, not park the send in an uninterruptible ioctl
# that SIGKILL cannot free.
#
# 8. POOL-ROOT PROPERTIES, BECAUSE PROPERTIES ARE NOT SENT.
#
# `zfs send` without -p carries no properties, so every received dataset inherits
# from this pool's root. Hence compression/atime/xattr/dnodesize are set here, to
# match what tank's root hands down.
#
# Not using -p is deliberate and worth knowing: -p would send tank's mountpoints
# too, so the backup's datasets would claim /Volumes/tank/media and collide with
# the live pool the moment anything mounted them. It would also send `readonly`
# and fight the destination's own setting.
#
# recordsize is left at default here, which is the one apparent gap and is not
# one: a non-raw stream carries its own block sizes, so tank's 1M records arrive
# as 1M blocks regardless of the property. The property only governs data written
# later, and nothing ever writes here — readonly=on, set by tank-backup.sh. It is
# left alone rather than set to 1M because 1M on the root would be wrong for
# `documents`, which is small mixed files.
#
# canmount=off on the root, matching tank: the root exists to hold the properties
# its children inherit, and to be the encryption root. It holds no data.
#
# --- HISTORY: WHY THERE IS A THIRD DRIVE ---------------------------------
#
# The first destination pool lived on a small stand-in device,
# STORAGE_DEVICE-7423J07. It was created, synced three times and restore-tested
# clean on 2026-08-23. By 00:18 on 2026-08-24 it was unimportable:
#
#     pool: tankbak   state: FAULTED
#     status: The pool metadata is corrupted.
#
# The likely cause is in the timeline, not the hardware. The last successful sync
# finished 23:18:52 and the drive was unplugged before 23:41 — and at that point
# tank-backup.sh only honoured --export on its happy path, so five exit paths,
# including the ordinary nothing-to-send one, left the pool IMPORTED. Unplugging
# an imported pool is the drive-pull failure performed deliberately. That hole
# was closed afterwards (maybe_export is now called on every exit path), which is
# why this drive gets a fair chance where the last one did not.
#
# Two things follow for whoever runs this:
#   - ALWAYS --export, and wait for it to return, before unplugging. It is the
#     single operational rule this pool depends on.
#   - Scrub after the first full send. A single-drive pool has no redundancy, so
#     ZFS can detect corruption here but never repair it. The scrub is how you
#     find out the drive is bad while tank still has the only good copy.
#
# --- USAGE ---------------------------------------------------------------
#
#   sudo sh tankbak-create.sh --list                    # what could be a target
#   sudo sh tankbak-create.sh --dry-run <serial>        # print the plan, do nothing
#   sudo sh tankbak-create.sh <serial>                  # create it
#   sudo sh tankbak-create.sh --force <serial>          # ...over an existing fs
#
# Exit codes:
#   0  created
#   1  refused
#   2  created, but a post-create check failed — READ THE OUTPUT

set -u

ZFS=/usr/local/zfs/bin/zfs
ZPOOL=/usr/local/zfs/bin/zpool
ZDB=/usr/local/zfs/bin/zdb

SRC_POOL=tank
DST_POOL=${TANK_BACKUP_DST:-tankbak}

DEV_DIR=${TANK_BACKUP_DEV_DIR:-/var/run/disk/by-serial}

# Where tank's passphrase lives, used only to prove the new pool's passphrase
# matches it. Read, never copied anywhere.
SRC_KEYFILE=${TANK_BACKUP_SRC_KEYFILE:-$("$ZFS" get -H -o value keylocation "$SRC_POOL" 2>/dev/null)}

MOUNTPOINT=${TANK_BACKUP_MOUNTPOINT:-/Volumes/$DST_POOL}

LOG=${TANK_BACKUP_LOG:-/var/log/tank-backup.log}

USAGE="usage: $0 [--list] [--dry-run] [--force] [--no-key-check] [--key-from-tank] <by-serial-name>"

DRY_RUN=0
FORCE=0
KEY_CHECK=1
DO_LIST=0
KEY_FROM_TANK=0
TARGET=

for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY_RUN=1 ;;
	--force) FORCE=1 ;;
	--no-key-check) KEY_CHECK=0 ;;
	--key-from-tank) KEY_FROM_TANK=1 ;;
	--list) DO_LIST=1 ;;
	-*)
		echo "unknown option: $arg" >&2
		echo "$USAGE" >&2
		exit 1
		;;
	*)
		if [ -n "$TARGET" ]; then
			echo "only one target may be given (got '$TARGET' and '$arg')" >&2
			exit 1
		fi
		TARGET=$arg
		;;
	esac
done

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"
}

# Bare echo for the parts that are a conversation with the operator rather than a
# record: the banner, the confirmation prompt, the next-steps block. Keeping them
# out of $LOG is what makes the log a history of the pool instead of a transcript.
say() { echo "$*"; }

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root: sudo sh $0 ..." >&2
	exit 1
fi

# Base device names (diskN, no partition suffix) belonging to any imported pool.
#
# -L resolves symlinks to real device nodes and -P prints full paths, so a pool
# imported by-serial still reports /dev/disk5s1 here — which is what makes this
# comparable to the target's resolved node. Comparing the by-serial names instead
# would miss a pool that happened to be imported via a different path, and that
# is precisely the case where the operator is least sure which drive is which.
in_use_disks() {
	for _p in $("$ZPOOL" list -H -o name 2>/dev/null); do
		"$ZPOOL" status -LP "$_p" 2>/dev/null |
			sed -n 's|.*/dev/\(disk[0-9][0-9]*\)[sp]*[0-9]*.*|\1|p'
	done | sort -u
}

# $1 = a diskN name. Echoes the value of a diskutil -plist key, or nothing.
disk_info() {
	diskutil info -plist "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null
}

# DeviceTreePath of every member of pool $1 — i.e. which physical USB port each
# one hangs off. See DESIGN 2a: both mirror members report the same string, so
# matching against this set is an exact "is this the same enclosure" test.
#
# Empty if the pool is not imported, which makes the check silently pass. That is
# reported rather than assumed — see the not-imported warning below.
pool_tree_paths() {
	for _d in $("$ZPOOL" status -LP "$1" 2>/dev/null |
		sed -n 's|.*/dev/\(disk[0-9][0-9]*\)[sp]*[0-9]*.*|\1|p' | sort -u); do
		_tp=$(disk_info "$_d" DeviceTreePath)
		[ -n "$_tp" ] && echo "$_tp"
	done | sort -u
}

list_candidates() {
	say "Devices in $DEV_DIR (whole disks only):"
	say ""
	_inuse=$(in_use_disks)
	_srctrees=$(pool_tree_paths "$SRC_POOL")
	for _link in "$DEV_DIR"/*; do
		[ -e "$_link" ] || continue
		_name=$(basename "$_link")
		# Skip the :N partition links; the target is always a whole disk.
		case "$_name" in *:*) continue ;; esac

		_node=$(readlink "$_link" 2>/dev/null)
		_dev=$(basename "${_node:-}")
		[ -n "$_dev" ] || continue

		_size=$(disk_info "$_dev" Size)
		_internal=$(disk_info "$_dev" Internal)
		_virtual=$(disk_info "$_dev" VirtualOrPhysical)
		_model=$(disk_info "$_dev" MediaName)

		_why=
		if echo "$_inuse" | grep -qx "$_dev"; then
			_why="IN USE by an imported pool"
		elif [ "$_internal" = "true" ]; then
			_why="internal"
		elif [ "$_virtual" = "Virtual" ]; then
			_why="virtual (disk image)"
		fi

		# Sharing tank's enclosure is a note, not a disqualification (DESIGN 2a),
		# so it annotates an otherwise-eligible drive rather than excluding it.
		_shared=
		if [ -n "$_srctrees" ] &&
			echo "$_srctrees" | grep -qxF "$(disk_info "$_dev" DeviceTreePath)"; then
			_shared="  (shares ${SRC_POOL}'s enclosure)"
		fi

		if [ -n "$_why" ]; then
			printf '  %-34s %-12s %-24s [not eligible: %s]\n' \
				"$_name" "$_dev" "${_model:-?}" "$_why"
		else
			printf '  %-34s %-12s %-24s %s bytes  <- eligible%s\n' \
				"$_name" "$_dev" "${_model:-?}" "${_size:-?}" "$_shared"
		fi
	done
	say ""
	if [ -n "$_srctrees" ]; then
		say "$SRC_POOL currently holds $("$ZPOOL" list -Hp -o allocated "$SRC_POOL" 2>/dev/null) allocated bytes."
	else
		say "NOTE: $SRC_POOL is not imported, so neither the same-enclosure check"
		say "      nor the does-it-fit check can run. Import it first."
	fi
}

if [ "$DO_LIST" = 1 ]; then
	list_candidates
	exit 0
fi

if [ -z "$TARGET" ]; then
	echo "no target given." >&2
	echo "$USAGE" >&2
	echo >&2
	list_candidates >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Refusals. Every one of these has to pass before anything is written.
# ---------------------------------------------------------------------------

# The passphrase prompt and the typed confirmation both need a terminal. Checked
# up front so a piped or launchd-run invocation fails here rather than half way
# through, at a prompt nothing can answer.
if [ ! -t 0 ] && [ "$DRY_RUN" != 1 ]; then
	echo "REFUSED: stdin is not a terminal. This is attended by design —" >&2
	echo "         it prompts for the passphrase and for confirmation." >&2
	exit 1
fi

LINK="$DEV_DIR/$TARGET"
if [ ! -e "$LINK" ]; then
	echo "REFUSED: no such device: $LINK" >&2
	echo >&2
	list_candidates >&2
	exit 1
fi
case "$TARGET" in
*:*)
	echo "REFUSED: '$TARGET' is a partition link. Give the whole-disk name" >&2
	echo "         (the one with no ':N' suffix) — zpool creates its own GPT." >&2
	exit 1
	;;
esac

NODE=$(readlink "$LINK" 2>/dev/null)
DEV=$(basename "${NODE:-}")
if [ -z "$DEV" ]; then
	echo "REFUSED: $LINK does not resolve to a device node." >&2
	exit 1
fi

if [ "$(disk_info "$DEV" Internal)" = "true" ]; then
	echo "REFUSED: $TARGET ($DEV) is an INTERNAL device." >&2
	echo "         The backup drive is external. Refusing without further" >&2
	echo "         argument — this is the check that stands between a typo" >&2
	echo "         and the boot disk." >&2
	exit 1
fi

if [ "$(disk_info "$DEV" VirtualOrPhysical)" = "Virtual" ]; then
	echo "REFUSED: $TARGET ($DEV) is a VIRTUAL device (a disk image)." >&2
	echo "         There is a leftover 8 TB image attached to this machine that" >&2
	echo "         reports its media name as 'tank'. Not that." >&2
	exit 1
fi

for used in $(in_use_disks); do
	if [ "$used" = "$DEV" ]; then
		echo "REFUSED: $TARGET ($DEV) is a member of an imported pool." >&2
		echo "         This is a mirror member or the backup itself. Stopping." >&2
		"$ZPOOL" status -LP 2>&1 | sed 's/^/         /' >&2
		exit 1
	fi
done

# Same enclosure as the source pool? See DESIGN 2a. REPORTED, NOT REFUSED — the
# create is safe either way; the consequence is at removal time, so the note here
# exists to make sure the removal procedure below gets read once.
SRC_TREES=$(pool_tree_paths "$SRC_POOL")
TARGET_TREE=$(disk_info "$DEV" DeviceTreePath)
# Reported in the banner, so it says what was actually established rather than
# implying a check that could not run.
SHARED_ENCLOSURE=0
ENCLOSURE="separate from $SRC_POOL"
if [ -z "$SRC_TREES" ]; then
	ENCLOSURE="UNKNOWN — $SRC_POOL is not imported, nothing was checked"
	say "WARNING: $SRC_POOL is not imported, so the same-enclosure check could"
	say "         not run and neither could the does-it-fit check. Importing it"
	say "         first is strongly preferred to skipping both."
elif [ -z "$TARGET_TREE" ]; then
	ENCLOSURE="UNKNOWN — no DeviceTreePath for $DEV"
	say "WARNING: could not read a DeviceTreePath for $DEV, so the"
	say "         same-enclosure check could not run."
elif echo "$SRC_TREES" | grep -qxF "$TARGET_TREE"; then
	SHARED_ENCLOSURE=1
	ENCLOSURE="SHARED with $SRC_POOL — see the removal procedure below"
fi

if "$ZPOOL" list -H -o name "$DST_POOL" >/dev/null 2>&1; then
	echo "REFUSED: a pool named '$DST_POOL' is already imported." >&2
	echo "         Export it first, and if you mean to replace it, destroy it" >&2
	echo "         explicitly — that is not a decision this script will make:" >&2
	echo "           sudo $ZPOOL destroy $DST_POOL" >&2
	exit 1
fi

DEV_BYTES=$(disk_info "$DEV" Size)
SRC_ALLOC=$("$ZPOOL" list -Hp -o allocated "$SRC_POOL" 2>/dev/null)
case "${DEV_BYTES:-x}${SRC_ALLOC:-x}" in
*[!0-9]*)
	say "WARNING: could not read a size for $DEV or an allocated size for"
	say "         $SRC_POOL, so the does-it-fit check was skipped."
	;;
*)
	if [ "$DEV_BYTES" -lt "$SRC_ALLOC" ]; then
		echo "REFUSED: $TARGET is $DEV_BYTES bytes; $SRC_POOL already holds" >&2
		echo "         $SRC_ALLOC allocated. The first full send cannot fit." >&2
		echo "         Cut a dataset from TANK_BACKUP_DATASETS, or use a" >&2
		echo "         bigger drive. \`media\` is the re-downloadable one, and" >&2
		echo "         cutting it is the payoff for splitting it off my_media." >&2
		exit 1
	fi
	# Headroom, not capacity. A pool at the brim fragments badly and leaves no
	# room for the source to grow before the next drive, and ZFS wants slack to
	# write at all. Warn rather than refuse: it is the operator's drive.
	if [ "$DEV_BYTES" -lt $((SRC_ALLOC * 2)) ]; then
		say "NOTE: $TARGET has under 2x $SRC_POOL's current $SRC_ALLOC allocated"
		say "      bytes. It fits today. Plan for it not fitting later."
	fi
	;;
esac

# ---------------------------------------------------------------------------
# Show the operator exactly what is about to happen, then make them type it.
# ---------------------------------------------------------------------------

# See DESIGN 4a. The pool ALWAYS ends at keylocation=prompt; --key-from-tank only
# changes how the passphrase gets in at create time, and the flip back happens
# immediately after. Validated here rather than at create time so an unusable
# flag costs nothing.
CREATE_KEYLOC=prompt
if [ "$KEY_FROM_TANK" = 1 ]; then
	case "${SRC_KEYFILE:-}" in
	file://*)
		_kf=${SRC_KEYFILE#file://}
		if [ ! -r "$_kf" ]; then
			echo "REFUSED: --key-from-tank given but $_kf is not readable." >&2
			exit 1
		fi
		CREATE_KEYLOC=$SRC_KEYFILE
		;;
	*)
		echo "REFUSED: --key-from-tank given, but ${SRC_POOL}'s keylocation is" >&2
		echo "         '${SRC_KEYFILE:-unreadable}', not a file:// locator." >&2
		echo "         There is no file to read the passphrase from." >&2
		exit 1
		;;
	esac
fi

CREATE_ARGS="-o ashift=12
-o failmode=continue
-o autoexpand=on
-o cachefile=none
-O encryption=aes-256-gcm
-O keyformat=passphrase
-O keylocation=$CREATE_KEYLOC
-O compression=lz4
-O atime=off
-O xattr=sa
-O dnodesize=auto
-O canmount=off
-O mountpoint=$MOUNTPOINT"

say ""
say "=============================================================="
say " TARGET      $TARGET"
say " device      $NODE  ($(disk_info "$DEV" MediaName))"
say " size        ${DEV_BYTES:-unknown} bytes"
say " usb port    ${TARGET_TREE:-unknown}"
say " enclosure   $ENCLOSURE"
say " new pool    $DST_POOL, encrypted, own key, passphrase at import"
say "=============================================================="
say ""
say "What is on it now:"
diskutil list "$DEV" 2>&1 | sed 's/^/  /'
say ""
say "ZFS labels found on it (a pool here would be destroyed):"
if [ -n "${NODE:-}" ]; then
	_labels=$("$ZDB" -l "/dev/r${DEV}s1" 2>&1 |
		grep -E "^ *(name|guid|state|txg):" | head -8)
	say "${_labels:-  none}"
fi
say ""
say "EVERYTHING ON THIS DEVICE WILL BE DESTROYED."
say ""
say "The command:"
say "  $ZPOOL create$([ "$FORCE" = 1 ] && echo ' -f') \\"
echo "$CREATE_ARGS" | sed 's/^/    /;s/$/ \\/'
say "    $DST_POOL $LINK"
say ""

if [ "$DRY_RUN" = 1 ]; then
	say "DRY RUN — nothing was changed."
	exit 0
fi

say "Type the drive's serial name to confirm, anything else to abort."
printf 'confirm> '
read -r answer </dev/tty || answer=
if [ "$answer" != "$TARGET" ]; then
	say "aborted (got '$answer', wanted '$TARGET')"
	exit 1
fi
say ""

# ---------------------------------------------------------------------------
# Create.
# ---------------------------------------------------------------------------

log "=== creating $DST_POOL on $TARGET ($NODE, ${DEV_BYTES:-?} bytes) ==="

if [ "$KEY_FROM_TANK" = 1 ]; then
	say "Reading the passphrase from ${SRC_POOL}'s key file — no prompt, and no"
	say "chance of a transcription error. keylocation is flipped to 'prompt'"
	say "immediately after, so nothing on this Mac will unlock $DST_POOL."
else
	say "Enter the passphrase for $DST_POOL — THE SAME ONE YOU USE FOR $SRC_POOL."
	say "zpool asks twice. If it does not match ${SRC_POOL}'s, the check after this"
	say "will say so. If it is a long random string, consider --key-from-tank"
	say "instead: a consistently mistyped passphrase cannot be corrected later,"
	say "because keyformat is immutable."
fi
say ""

# shellcheck disable=SC2086
if [ "$FORCE" = 1 ]; then
	"$ZPOOL" create -f $CREATE_ARGS "$DST_POOL" "$LINK"
else
	"$ZPOOL" create $CREATE_ARGS "$DST_POOL" "$LINK"
fi
rc=$?

if [ "$rc" -ne 0 ]; then
	log "FAIL: zpool create exited $rc — $DST_POOL was NOT created"
	say ""
	say "If it objected to an existing filesystem or pool on the device, that is"
	say "this script declining to force by default. Re-read the device summary"
	say "above, and if it really is the right drive:"
	say "  sudo sh $0 --force $TARGET"
	exit 1
fi
log "created $DST_POOL"

# The flip back to prompt, immediately, so the window in which this Mac holds a
# locator for the backup is as short as the script can make it. Treated as a hard
# failure rather than a warning: a backup pool that silently kept pointing at
# tank's key file is precisely the thing DESIGN 4 exists to prevent, and it would
# be invisible afterwards — everything would simply keep working.
if [ "$KEY_FROM_TANK" = 1 ]; then
	if "$ZFS" set keylocation=prompt "$DST_POOL"; then
		log "keylocation flipped to prompt"
	else
		log "FAIL: could not set keylocation=prompt on $DST_POOL."
		log "      It is still pointing at ${SRC_POOL}'s key file, which means this"
		log "      Mac can unlock the backup. Fix before going any further:"
		log "        sudo $ZFS set keylocation=prompt $DST_POOL"
	fi
fi

# ---------------------------------------------------------------------------
# Post-create checks. The pool exists either way; these decide whether to
# trust it with 1 TB overnight.
# ---------------------------------------------------------------------------

bad=0

check() {
	_what=$1
	_want=$2
	_got=$3
	if [ "$_got" = "$_want" ]; then
		log "  ok   $_what = $_got"
	else
		log "  FAIL $_what = '$_got', wanted '$_want'"
		bad=$((bad + 1))
	fi
}

log "verifying the properties that cannot be changed later:"
check "encryption" "aes-256-gcm" "$("$ZFS" get -H -o value encryption "$DST_POOL" 2>/dev/null)"
check "keyformat" "passphrase" "$("$ZFS" get -H -o value keyformat "$DST_POOL" 2>/dev/null)"
check "keylocation" "prompt" "$("$ZFS" get -H -o value keylocation "$DST_POOL" 2>/dev/null)"
check "encryptionroot" "$DST_POOL" "$("$ZFS" get -H -o value encryptionroot "$DST_POOL" 2>/dev/null)"
check "ashift" "12" "$("$ZPOOL" get -H -o value ashift "$DST_POOL" 2>/dev/null)"
check "failmode" "continue" "$("$ZPOOL" get -H -o value failmode "$DST_POOL" 2>/dev/null)"
check "canmount" "off" "$("$ZFS" get -H -o value canmount "$DST_POOL" 2>/dev/null)"

# tank/media and tank/my_media are recordsize=1M. A non-raw stream carries its
# own block sizes, so the receive needs this feature regardless of any property
# on this side. It is enabled by default on a fresh pool — this asserts it rather
# than assuming, because the failure would surface as a refused send hours in.
lb=$("$ZPOOL" get -H -o value feature@large_blocks "$DST_POOL" 2>/dev/null)
case "$lb" in
enabled | active) log "  ok   feature@large_blocks = $lb" ;;
*)
	log "  FAIL feature@large_blocks = '$lb' — 1M records from $SRC_POOL will not send"
	bad=$((bad + 1))
	;;
esac

# The passphrase check. See DESIGN 5 — this is the only thing that can catch a
# confidently mistyped passphrase, and the alternative to catching it here is
# catching it at a restore.
if [ "$KEY_CHECK" = 1 ]; then
	case "${SRC_KEYFILE:-}" in
	file://*)
		if [ "$KEY_FROM_TANK" = 1 ]; then
			# Not an independent check in this mode — the passphrase came from
			# this very file, so a pass proves only that the round trip works.
			# Still worth running: it exercises unload/load, which is what every
			# future import does, and a failure here would be a real surprise.
			log "re-loading the key from ${SRC_POOL}'s file (round-trip, not a"
			log "  comparison — --key-from-tank makes a match true by construction)"
		else
			log "checking the passphrase against ${SRC_POOL}'s"
		fi
		if "$ZFS" unload-key "$DST_POOL" >/dev/null 2>&1; then
			if "$ZFS" load-key -L "$SRC_KEYFILE" "$DST_POOL" >/dev/null 2>&1; then
				log "  ok   the passphrase matches ${SRC_POOL}'s"
			else
				bad=$((bad + 1))
				log "  FAIL the passphrase does NOT match ${SRC_POOL}'s."
				log "       The pool is fine and importable — but its passphrase is"
				log "       something other than what you believe it is, and only you"
				log "       know what you typed. Decide now, not at a restore:"
				log "         sudo $ZFS change-key $DST_POOL"
				log "       Then re-run this check:"
				log "         sudo $ZFS unload-key $DST_POOL"
				log "         sudo $ZFS load-key -L $SRC_KEYFILE $DST_POOL"
				# Leave the key loaded either way, so the sync that follows does not
				# prompt again in the same sitting. If this also fails the operator
				# has now mistyped it twice; say so rather than exiting with the
				# pool locked and no explanation.
				say ""
				say "Re-enter the passphrase you just used, to leave the key loaded:"
				if ! "$ZFS" load-key "$DST_POOL" </dev/tty; then
					log "       and the key could not be reloaded either — $DST_POOL is"
					log "       locked. Nothing is lost; load it when you next need it:"
					log "         sudo $ZFS load-key $DST_POOL"
				fi
			fi
		else
			log "  SKIP could not unload the key to test it; checked nothing."
		fi
		;;
	*)
		log "  SKIP ${SRC_POOL}'s keylocation is '${SRC_KEYFILE:-unreadable}', not a"
		log "       file:// locator, so the passphrase could not be compared."
		;;
	esac
fi

say ""
"$ZPOOL" status -LP "$DST_POOL" 2>&1 | tee -a "$LOG"
"$ZFS" get -H -o property,value \
	encryption,keyformat,keylocation,keystatus,encryptionroot,compression,canmount \
	"$DST_POOL" 2>&1 | tee -a "$LOG"

if [ "$bad" -gt 0 ]; then
	log "=== done (exit 2) — $bad check(s) failed, READ THEM ==="
	exit 2
fi

log "=== done (exit 0) — $DST_POOL created and verified ==="

say ""
say "=============================================================="
say " NEXT, IN ORDER"
say "=============================================================="
say ""
say "1. Write down the passphrase somewhere that survives this machine."
say "   It is ${SRC_POOL}'s passphrase, so it is probably already written down —"
say "   confirm that rather than assume it. A backup locked behind a lost"
say "   passphrase is a brick, and there is no recovery from one."
say ""
say "2. Payload for the restore test, BEFORE the first sync:"
say "     sudo sh tests/backup-restore/test-backup-restore.sh payload"
say ""
say "3. The first sync. This is a FULL send of"
say "   $("$ZPOOL" list -Hp -o allocated "$SRC_POOL" 2>/dev/null) bytes over USB — hours, not minutes."
say "   It is resumable (recv -s), so an interruption costs a rerun, not the work:"
say "     sudo sh scripts/nas-backup/tank-backup.sh --dry-run"
say "     sudo sh scripts/nas-backup/tank-backup.sh"
say ""
say "4. Scrub it before trusting it. A single drive has no redundancy, so this"
say "   detects corruption it cannot repair — which is still worth knowing while"
say "   $SRC_POOL holds the only good copy. Expect hours again:"
say "     sudo $ZPOOL scrub $DST_POOL"
say "     $ZPOOL status $DST_POOL"
say ""
say "5. Then the rest of the restore test: export, UNPLUG, replug, verify."
say "     tests/backup-restore/README.md"
say ""
say "6. From then on, every single time, without exception:"
say "     sudo sh scripts/nas-backup/tank-backup.sh --export"
say "   and wait for it to return before unplugging. The last backup pool was"
say "   lost to an unplug while imported. See HISTORY at the top of this file."
say ""

if [ "$SHARED_ENCLOSURE" = 1 ]; then
	say "=============================================================="
	say " REMOVING THIS DRIVE, GIVEN IT SHARES ${SRC_POOL}'s ENCLOSURE"
	say "=============================================================="
	say ""
	say "Creating the pool here is safe and the drive is in no vdev of ${SRC_POOL}'s."
	say "The one consequence is at removal: a device-removal event can make a"
	say "single-bridge enclosure re-enumerate, and if that drops ${SRC_POOL}'s LUNs"
	say "too then $SRC_POOL suspends. failmode=wait, so Jellyfin blocks in an ioctl"
	say "SIGKILL cannot free. It is recoverable, not dangerous."
	say ""
	say "Option A — pull it, and fix $SRC_POOL if it complains. Try this first:"
	say "     sudo sh scripts/nas-backup/tank-backup.sh --export"
	say "     <remove the backup drive>"
	say "     sudo $ZPOOL clear $SRC_POOL        # ONLY if $SRC_POOL suspended"
	say ""
	say "Option B — no risk, more steps. Switch to this if A ever disturbs $SRC_POOL:"
	say "     sudo sh scripts/nas-backup/tank-backup.sh --export"
	say "     sudo launchctl bootout system/local.jellyfin"
	say "     sudo $ZPOOL export $SRC_POOL"
	say "     <power the enclosure off, remove the drive, power it on>"
	say "     sudo launchctl bootstrap system /Library/LaunchDaemons/local.jellyfin.plist"
	say ""
	say "In B, $SRC_POOL comes back on its own — tank-boot-unlock.sh's WatchPaths"
	say "fires when the disks reappear, which is what it was added for."
	say ""
fi
exit 0
