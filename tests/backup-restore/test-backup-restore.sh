#!/bin/sh
#
# test-backup-restore.sh — prove that the offline backup can actually be
# restored from, rather than that the send exited 0.
#
# WHY THIS IS A SEPARATE TEST FROM "DID THE SYNC WORK"
# tank-backup.sh exiting 0 proves a stream was accepted. It does not prove the
# bytes are correct, that the destination pool can be imported on its own, that
# its passphrase works, or that the files are readable. An untested backup is a
# guess, and the moment you find out is the moment you needed it.
#
# This is partly manual on purpose: the middle of it is physically unplugging the
# drive, which is the whole point of an offline backup and cannot be scripted.
# See README.md in this directory for the full procedure. The phases here are the
# parts a script should own — generating a known payload and verifying it
# afterwards byte for byte.
#
# PHASES
#   payload   write known random files into every replicated dataset and record
#             a sha256 manifest. Run this BEFORE the sync you want to test.
#   verify    mount the destination read-only and check every file in the
#             manifest against it. Run this AFTER export / unplug / replug /
#             import.
#   cleanup   remove the payload from the source. The next sync propagates the
#             deletion to the destination.
#
# The manifest lives in /var/tmp rather than in this directory because it
# describes random bytes and has no business in git.
#
# Usage:
#   sudo sh test-backup-restore.sh payload
#   ... run tank-backup.sh, export, unplug, replug ...
#   sudo sh test-backup-restore.sh verify
#   sudo sh test-backup-restore.sh cleanup

set -u

ZFS=/usr/local/zfs/bin/zfs
ZPOOL=/usr/local/zfs/bin/zpool

SRC_POOL=tank
DST_POOL=${TANK_BACKUP_DST:-tankbak}
DATASETS=${TANK_BACKUP_DATASETS:-"my_media media documents"}

SCRATCH=.restoretest
MANIFEST=/var/tmp/tank-restore-manifest.txt

# Small but not trivial. Big enough to span multiple records at 1M recordsize on
# the media datasets, so this exercises more than a single block, and small
# enough that a slow USB stick is not the point of the exercise.
FILES_PER_DS=3
FILE_KB=2048

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root: sudo sh $0 <payload|verify|cleanup>" >&2
	exit 1
fi

mnt() { "$ZFS" get -H -o value mountpoint "$1" 2>/dev/null; }

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

case "${1:-}" in

payload)
	echo "=== writing payload into $SRC_POOL ==="
	: >"$MANIFEST"
	for name in $DATASETS; do
		src="$SRC_POOL/$name"
		m=$(mnt "$src")
		if [ -z "$m" ] || [ ! -d "$m" ]; then
			echo "FAIL: no mountpoint for $src" >&2
			exit 1
		fi
		mkdir -p "$m/$SCRATCH"
		i=1
		while [ "$i" -le "$FILES_PER_DS" ]; do
			f="$m/$SCRATCH/payload-$i.bin"
			dd if=/dev/urandom of="$f" bs=1024 count="$FILE_KB" 2>/dev/null
			# Manifest records the dataset-relative path, not the absolute one,
			# so the same manifest verifies against the destination's different
			# mountpoint without any rewriting.
			printf '%s  %s/%s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" \
				"$name" "$SCRATCH/payload-$i.bin" >>"$MANIFEST"
			i=$((i + 1))
		done
		echo "  $src: $FILES_PER_DS x ${FILE_KB}K"
	done
	# Force a txg so `written@` reflects this immediately — tank-backup.sh reads
	# it to decide whether there is anything to send, and POSIX sync(8) does not
	# move on-disk accounting.
	"$ZPOOL" sync "$SRC_POOL"
	echo
	echo "manifest: $MANIFEST"
	wc -l <"$MANIFEST" | awk '{print "  " $1 " files recorded"}'
	echo
	echo "Next: sudo sh scripts/nas-backup/tank-backup.sh --export"
	echo "      then unplug, replug, and run: sudo sh $0 verify"
	;;

verify)
	if [ ! -s "$MANIFEST" ]; then
		echo "no manifest at $MANIFEST — run the payload phase first" >&2
		exit 1
	fi

	echo "=== verifying $DST_POOL against $MANIFEST ==="

	# Import if needed. This is the step that proves the drive stands alone: a
	# cold import of a pool that was exported and physically disconnected.
	if ! "$ZPOOL" list -H -o name "$DST_POOL" >/dev/null 2>&1; then
		echo "importing $DST_POOL"
		"$ZPOOL" import "$DST_POOL" || {
			bad "could not import $DST_POOL"
			exit 1
		}
	fi
	ok "$DST_POOL imported"

	# And this is the step that proves the passphrase works away from the
	# machine that wrote it — the whole value of an independently-encrypted
	# destination rests on this prompt succeeding.
	keystatus=$("$ZFS" get -H -o value keystatus "$DST_POOL" 2>/dev/null)
	if [ "$keystatus" != "available" ]; then
		echo "loading key for $DST_POOL"
		"$ZFS" load-key "$DST_POOL" || {
			bad "could not load the key for $DST_POOL"
			exit 1
		}
	fi
	ok "$DST_POOL key loaded"

	# recv -u left these unmounted, which is correct and is why this is here.
	# readonly=on means they mount read-only; that is the intent, not a problem.
	for name in $DATASETS; do
		dst="$DST_POOL/$name"
		if [ "$("$ZFS" get -H -o value mounted "$dst" 2>/dev/null)" != "yes" ]; then
			"$ZFS" mount "$dst" 2>/dev/null
		fi
		if [ "$("$ZFS" get -H -o value mounted "$dst" 2>/dev/null)" = "yes" ]; then
			ok "$dst mounted"
		else
			bad "$dst could not be mounted"
		fi
	done

	echo
	echo "--- checksums ---"
	while read -r want rel; do
		[ -z "${want:-}" ] && continue
		# rel is "<dataset>/<path>"; map it onto the destination's mountpoint.
		ds_name=${rel%%/*}
		sub=${rel#*/}
		dm=$(mnt "$DST_POOL/$ds_name")
		f="$dm/$sub"
		if [ ! -f "$f" ]; then
			bad "missing on destination: $rel"
			continue
		fi
		got=$(shasum -a 256 "$f" | awk '{print $1}')
		if [ "$got" = "$want" ]; then
			ok "$rel"
		else
			bad "$rel CHECKSUM MISMATCH"
			echo "       want $want"
			echo "       got  $got"
		fi
	done <"$MANIFEST"

	echo
	echo "--- destination is genuinely read-only ---"
	for name in $DATASETS; do
		dm=$(mnt "$DST_POOL/$name")
		if touch "$dm/.writeprobe" 2>/dev/null; then
			bad "$DST_POOL/$name accepted a write — readonly=on is not in effect"
			rm -f "$dm/.writeprobe"
		else
			ok "$DST_POOL/$name rejected a write"
		fi
	done

	echo
	echo "=========================================="
	echo "passed $pass, failed $fail"
	[ "$fail" -eq 0 ] || exit 1
	echo
	echo "The backup is restorable. Export before unplugging:"
	echo "  sudo $ZPOOL export $DST_POOL"
	;;

cleanup)
	echo "=== removing payload from $SRC_POOL ==="
	for name in $DATASETS; do
		m=$(mnt "$SRC_POOL/$name")
		if [ -n "$m" ] && [ -d "$m/$SCRATCH" ]; then
			rm -rf "$m/$SCRATCH"
			echo "  removed $m/$SCRATCH"
		fi
	done
	"$ZPOOL" sync "$SRC_POOL"
	rm -f "$MANIFEST"
	echo
	echo "The payload is still on the destination until the next sync, which"
	echo "will propagate the deletion. That is itself worth watching once: it is"
	echo "the behaviour that makes a mirror-style backup follow you off a cliff"
	echo "if you delete something and sync before noticing."
	;;

*)
	echo "usage: sudo sh $0 <payload|verify|cleanup>" >&2
	exit 1
	;;
esac
