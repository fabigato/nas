#!/bin/sh
#
# tank-boot-unlock.sh — bring the encrypted pool `tank` fully online at boot.
#
# An encrypted pool needs three distinct steps, in this order:
#   1. zpool import    attach the disks
#   2. zfs load-key    decrypt
#   3. zfs mount       make files visible
# The OpenZFS package's own daemons do 1, attempt 3, and never do 2 — they
# assume unencrypted pools. So we switch them off with /etc/zfs/noautoimport
# and own the whole chain here.
#
# Rollback: sudo launchctl bootout system/local.tank-boot-unlock
#           sudo rm /Library/LaunchDaemons/local.tank-boot-unlock.plist
#           sudo rm /etc/zfs/noautoimport
# The stock daemons then resume as if we were never here.

set -u

ZPOOL=/usr/local/zfs/bin/zpool
ZFS=/usr/local/zfs/bin/zfs
POOL=tank
BYSERIAL=/var/run/disk/by-serial

# Import by serial, not by-id: `zpool status` then prints USB30_DISK00/01 instead
# of GPT UUIDs. SMART does not work through the Orico bridge, so zpool status is
# the ONLY map from a failed mirror member to a physical bay. Keep it readable.
DISK0="$BYSERIAL/USB30_DISK00-20170331000C3"
DISK1="$BYSERIAL/USB30_DISK01-20170331000C3"

LOG=/var/log/tank-boot-unlock.log
WAIT_SECS=120

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

log "--- start (pid $$) ---"

# 1. Wait for the enclosure to enumerate and InvariantDisks to publish its
#    by-serial symlinks. USB is slow at boot and launchd guarantees no ordering
#    between us and org.openzfsonosx.InvariantDisks, so poll rather than assume.
waited=0
while [ "$waited" -lt "$WAIT_SECS" ]; do
	[ -e "$DISK0" ] && [ -e "$DISK1" ] && break
	waited=$((waited + 1))
	sleep 1
done
if [ ! -e "$DISK0" ] || [ ! -e "$DISK1" ]; then
	log "FAIL: by-serial links still absent after ${waited}s."
	log "      Enclosure powered off, unplugged, or a disk is dead. Giving up."
	exit 1
fi
log "both disks visible after ${waited}s"

# 2. Import — unless something already did it. Never assume we ran first.
if "$ZPOOL" list -H -o name "$POOL" >/dev/null 2>&1; then
	log "pool already imported; skipping import"
else
	# -N: attach only — do not mount. Steps 3 and 4 decrypt and mount explicitly.
	# No -l here: this build errors with "-l is incompatible with -N", so the key
	# gets loaded in step 3 instead. One command per step, which is clearer anyway.
	"$ZPOOL" import -N -d "$BYSERIAL" "$POOL" >>"$LOG" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "FAIL: zpool import exited $rc"
		exit 1
	fi
	log "import OK"
fi

# 3. Decrypt. This is the step the stock daemons never do. Guarded on keystatus so
#    it is also correct when something else imported the pool ahead of us.
keystatus=$("$ZFS" get -H -o value keystatus "$POOL" 2>/dev/null || echo unknown)
if [ "$keystatus" = "available" ]; then
	log "key already available"
else
	log "keystatus=$keystatus — loading key"
	"$ZFS" load-key "$POOL" >>"$LOG" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "FAIL: zfs load-key exited $rc — check /etc/zfs/keys/tank.key"
		log "      (passphrase is escrowed in pass at nas/tank-key)"
		exit 1
	fi
	log "load-key OK"
fi

# 4. Mount. `tank` itself is canmount=off, so this mounts its child datasets.
"$ZFS" mount -a >>"$LOG" 2>&1
rc=$?
[ "$rc" -ne 0 ] && log "WARN: zfs mount -a exited $rc (continuing)"

log "health: $("$ZPOOL" list -H -o name,health "$POOL" 2>&1)"
log "datasets:"
"$ZFS" list -r -H -o name,mounted,mountpoint "$POOL" >>"$LOG" 2>&1
log "--- done ---"
exit 0
