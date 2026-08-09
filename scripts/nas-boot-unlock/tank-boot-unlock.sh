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
# ############################################################################
# # HARD PREREQUISITE — Full Disk Access. Without it NOTHING below works.    #
# ############################################################################
# macOS TCC denies raw-device reads to processes with no Full Disk Access
# grant. A LaunchDaemon has no such grant by default, so `zpool` gets EPERM on
# every /dev/diskN it tries, silently skips them all, and reports
# "cannot import 'tank': no such pool available" — indistinguishable from the
# enclosure being unplugged. This cost two cold boots and three wrong theories.
#
# These three must be listed in System Settings > Privacy & Security >
# Full Disk Access (use the + button, then Shift-Cmd-G to type the path):
#   /usr/local/zfs/bin/zpool
#   /usr/local/zfs/bin/zfs
#   /usr/local/zfs/bin/zdb
# They are Developer ID signed (Team 735AM5QEU3), so grants survive. SIP is on,
# so TCC.db cannot be edited directly, and manually-installed PPPC profiles are
# ignored without MDM — the GUI is the only route. /bin/sh does NOT need the
# grant: TCC attributes the access to the child binary, not the interpreter.
#
# Re-check this after every OpenZFS upgrade — re-signed binaries can invalidate
# the grants, and the failure looks exactly like dead hardware.
#
# TESTING — do not use a reboot as your test loop:
#   sudo zpool export tank
#   sudo launchctl kickstart -k system/local.tank-boot-unlock
#   launchctl print system/local.tank-boot-unlock | grep 'last exit'
# kickstart spawns this under launchd with no terminal FDA inheritance, so it
# reproduces the boot TCC context exactly, in ~70s instead of a cold boot.
# Trust `last exit code`, not just this script's log. Note that running it by
# hand from a terminal proves NOTHING: sudo inherits the terminal app's FDA
# grant, which is precisely why every manual run succeeded while every boot
# failed.
#
# Rollback: sudo launchctl bootout system/local.tank-boot-unlock
#           sudo rm /Library/LaunchDaemons/local.tank-boot-unlock.plist
#           sudo rm /etc/zfs/noautoimport
# The stock daemons then resume as if we were never here.

set -u

ZPOOL=/usr/local/zfs/bin/zpool
ZFS=/usr/local/zfs/bin/zfs
ZDB=/usr/local/zfs/bin/zdb
POOL=tank
BYSERIAL=/var/run/disk/by-serial

# Import by serial, not by-id: `zpool status` then prints USB30_DISK00/01 instead
# of GPT UUIDs. SMART does not work through the Orico bridge, so zpool status is
# the ONLY map from a failed mirror member to a physical bay. Keep it readable.
DISK0="$BYSERIAL/USB30_DISK00-20170331000C3"
DISK1="$BYSERIAL/USB30_DISK01-20170331000C3"

LOG=/var/log/tank-boot-unlock.log
WAIT_SECS=120
IMPORT_TRIES=12
IMPORT_DELAY=5

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Is the raw device read being refused by TCC? Returns 0 if yes.
#
# This is THE failure mode (see the header), so it gets tested explicitly rather
# than left to be re-derived from an rc. EPERM is the whole signal: an
# exclusive-open conflict — the theory this script chased for two cold boots —
# reports EBUSY / "Resource busy" instead, so the errno alone tells the two
# apart. `2>&1 >/dev/null` pipes dd's stderr, not its stdout, to grep.
tcc_blocked() {
	for link in "$DISK0" "$DISK1"; do
		node=$(readlink "$link" 2>/dev/null)
		[ -n "$node" ] || continue
		part="/dev/r$(basename "$node")s1"
		if dd if="$part" of=/dev/null bs=8192 count=1 2>&1 >/dev/null |
			grep -q 'Operation not permitted'; then
			return 0
		fi
	done
	return 1
}

# Snapshot of everything that could make a label scan come back empty, taken at
# the instant it comes back empty. Added 2026-08-09 after the second failed cold
# boot, and it is what cracked the case: `dd` and `zdb -l` both came back
# "Operation not permitted" while lsof reported the device held by <nobody>,
# which killed the exclusive-open theory and pointed at TCC. Kept because it is
# still the fastest way to tell the remaining failure classes apart:
#   EPERM        -> Full Disk Access missing (see header)
#   EBUSY        -> something really does hold the device
#   rc=0 + no labels -> the disks are readable but not ours / wiped
#
# $1 = attempt label. lsof only when $1 = final: it walks every process, which is
# slow at boot and can block on a wedged device, so it must not delay the retries.
diagnose() {
	log "  --- diagnostics ($1) ---"
	log "  /dev/zfs: $(ls -l /dev/zfs 2>&1)"
	for link in "$DISK0" "$DISK1"; do
		node=$(readlink "$link" 2>/dev/null)
		log "  $(basename "$link") -> ${node:-<unresolved>}"
		[ -n "$node" ] || continue
		# ZFS reads labels from the raw device; the pool lives on partition 1.
		part="/dev/r$(basename "$node")s1"
		dd if="$part" of=/dev/null bs=8192 count=1 >/dev/null 2>&1
		log "    dd $part rc=$?   (0 = raw I/O works, nonzero = busy or unreadable)"
		lbl=$("$ZDB" -l "$part" 2>&1 | grep -E "name:|guid:|failed|cannot|zdb:" | head -3)
		log "    zdb -l: ${lbl:-<no output>}"
		if [ "$1" = final ]; then
			held=$(/usr/sbin/lsof -w "$node" "$part" 2>/dev/null | tail -n +2 |
				awk '{print $1"("$2")"}' | sort -u | tr '\n' ' ')
			log "    open by: ${held:-<nobody>}"
		fi
	done
	# Nameless scan. Distinguishes "sees no pool at all" from "sees tank but the
	# import by name still fails" — two completely different bugs.
	log "  nameless scan of $BYSERIAL:"
	"$ZPOOL" import -d "$BYSERIAL" >>"$LOG" 2>&1
	log "  --- end diagnostics ---"
}

# One import attempt, timed. Sets $out, $rc, $took (seconds) for the caller.
#
# The duration is logged for the record, but do NOT reason from it — measured
# 2026-08-09: a successful nameless scan with the devices free is 0.302s, so a
# sub-second failure proves nothing. The ~22s a warm import sometimes takes is
# drive idle/standby wake-up, not scan work. An earlier version of this comment
# read the sub-second boot failures as "zpool never opened the disks"; that
# happened to point the right way, but the inference was unsound and the real
# evidence was the errno, not the clock.
timed_import() {
	t0=$(date +%s)
	out=$("$ZPOOL" import -N "$@" "$POOL" 2>&1)
	rc=$?
	took=$(($(date +%s) - t0))
	return "$rc"
}

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
	# RETRY, and do not treat the first failure as fatal.
	#
	# History, because the obvious diagnosis was wrong twice:
	#   Cold boot 1 (15:12) — single import, failed. Blamed on a race: the
	#     symlinks appeared ~150ms earlier, so "the disks can't be ready yet".
	#   Cold boot 2 (15:51) — 12 attempts over 60s, ALL failed identically.
	#     That killed the race theory. The drives are never even spun down: the
	#     Orico has its own PSU and stays powered while the Mac is off. /dev/zfs
	#     existed at 15:51:50, 19s before the first attempt. The by-serial links
	#     were created once at 15:52:06 and never rewritten. And the very same
	#     command, run warm minutes later, imported the pool cleanly — `zdb -l`
	#     showed all labels intact, txg 26523 on both members.
	#
	#   Cold boot 3 (20:45) — 12 attempts, all failed, but diagnose() fired and
	#     the answer was in it: EPERM on the raw devices, held by <nobody>.
	#
	# SOLVED 2026-08-09: it was TCC / Full Disk Access. See the header. The
	# kernel had been saying so all along in the unified log —
	#   /usr/bin/log show --start <boot> --end <+2min> --style compact \
	#     | grep 'deny(1)'
	#   System Policy: zpool(520) deny(1) file-read-data /dev/disk4s1
	#   System Policy: zpool(520) deny(1) file-read-data /dev/disk0
	# — while every theory above was reasoned from this script's own log instead.
	# The lesson worth more than the fix: when a privileged op fails with
	# "Operation not permitted" on macOS, ask the OS who denied what before
	# theorising about the application.
	#
	# The give-away was in the log the whole time too: every launchd run had a
	# low PID (302/304/308) and failed; every hand-run had a high PID and worked.
	#
	# The retries below are KEPT, but be honest about what they buy. They did not
	# fix this and cannot: a missing TCC grant does not heal on retry, which is
	# why attempt 1 now bails out via tcc_blocked() instead of burning 60s. What
	# they still cover is genuine USB re-enumeration flakiness on this JMicron
	# bridge. Do NOT read the ladder below as coverage — all three paths failed
	# identically at all three cold boots, because TCC blocks the device reads,
	# not the scan method.
	#
	# Two escape hatches from attempt 4 on, both genuinely different code paths
	# from directory scanning, so one may survive whatever blocks the other:
	#   cachefile — /etc/zfs/zpool.cache records the by-serial vdev paths, so a
	#               cachefile import keeps zpool status readable. Try it first.
	#   -d /dev   — last resort. Works, but names the members diskXs1, which are
	#               not stable across boots. SMART does not work through this
	#               enclosure, so zpool status is the only map from a failed
	#               mirror member to a physical bay; if this is what got us in,
	#               export and re-import by-serial once the machine is settled.
	#
	# -N: attach only — do not mount. Steps 3 and 4 decrypt and mount explicitly.
	# No -l here: this build errors with "-l is incompatible with -N", so the key
	# gets loaded in step 3 instead. One command per step, which is clearer anyway.
	attempt=0
	rc=1
	via=
	while [ "$attempt" -lt "$IMPORT_TRIES" ]; do
		attempt=$((attempt + 1))

		if timed_import -d "$BYSERIAL"; then
			via="by-serial"
			break
		fi
		log "import attempt $attempt/$IMPORT_TRIES failed (rc=$rc, ${took}s): $out"

		if [ "$attempt" -ge 4 ]; then
			if timed_import; then
				via="cachefile"
				break
			fi
			log "  fallback cachefile failed (rc=$rc, ${took}s): $out"

			if timed_import -d /dev; then
				via="/dev"
				break
			fi
			log "  fallback -d /dev failed (rc=$rc, ${took}s): $out"
		fi

		if [ "$attempt" -eq 1 ]; then
			diagnose "attempt 1"
			# A missing Full Disk Access grant cannot heal on retry, and it is the
			# only fault that has ever actually occurred here. Say so and stop,
			# instead of spending 60s re-proving it and then blaming the hardware.
			if tcc_blocked; then
				log "FAIL: raw device reads denied (EPERM) — the pool is NOT missing."
				log "      Cause: macOS TCC. This daemon has no Full Disk Access, so"
				log "      zpool cannot open /dev/diskN and reports the disks absent."
				log "      Fix: System Settings > Privacy & Security > Full Disk Access,"
				log "      '+' then Shift-Cmd-G, add all three:"
				log "        /usr/local/zfs/bin/zpool"
				log "        /usr/local/zfs/bin/zfs"
				log "        /usr/local/zfs/bin/zdb"
				log "      Then re-test IN THE BOOT CONTEXT (not from a terminal):"
				log "        sudo launchctl kickstart -k system/local.tank-boot-unlock"
				log "      Confirm the denials are gone:"
				log "        /usr/bin/log show --start <boot> --end <+2min> \\"
				log "          --style compact | grep 'deny(1)'"
				log "      Re-check after every OpenZFS upgrade — re-signing the"
				log "      binaries can silently invalidate the grants."
				exit 1
			fi
		fi
		[ "$attempt" -lt "$IMPORT_TRIES" ] && sleep "$IMPORT_DELAY"
	done
	if [ "$rc" -ne 0 ]; then
		diagnose final
		log "FAIL: zpool import still failing after $attempt attempts"
		log "      Every path failed. Read the diagnostics above before theorising:"
		log "      dd rc tells you if raw I/O works, zdb -l if the labels read,"
		log "      'open by' who else holds the device."
		log "      NOTE: this is NOT the Full Disk Access fault — tcc_blocked()"
		log "      cleared that at attempt 1. So this is something genuinely new."
		log "      Next step is the unified log, not another theory:"
		log "        /usr/bin/log show --start <boot> --end <+2min> \\"
		log "          --style compact | grep -E 'deny\\(1\\)|zpool|zdb'"
		log "      Manual recovery: sudo $0"
		exit 1
	fi
	log "import OK on attempt $attempt via $via (${took}s)"
	if [ "$via" != "by-serial" ]; then
		log "WARN: imported via $via, not by-serial. This is the diagnosis we were"
		log "      after — the by-serial directory scan is what fails at boot."
		[ "$via" = "/dev" ] && log "WARN: members are now named diskXs1. Export and" &&
			log "      re-import with -d $BYSERIAL to restore readable bay names."
	fi
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
