#!/bin/sh
# Observation harness for the TODO-1 drive-pull test.
# Samples pool + device state every 2s and logs anything that changes, with
# timestamps, so the DEGRADED transition can be read back after the fact.
#
# Deliberately uses no sudo: `zpool status` and the by-serial symlinks are
# readable as an ordinary user, and zed's log is mode 644.
#
# Usage: sh watch-pull.sh <logfile>   (run in background, Ctrl-C / kill to stop)

set -u
PATH=/usr/local/zfs/bin:$PATH
export PATH

LOG=${1:?usage: watch-pull.sh <logfile>}
ZEDLOG=/private/var/log/org.openzfsonosx.zed.err

# Byte offset into zed's log at start, so we only report lines the test caused.
zed_off=$(wc -c < "$ZEDLOG" 2>/dev/null || echo 0)

ts() { date '+%H:%M:%S'; }

# One-line fingerprint of everything we care about; we only dump full state
# when this string changes, which keeps the log readable.
fingerprint() {
    zpool status tank 2>&1 | awk '/USB30_DISK|state:|mirror-0|tank /{printf "%s|", $0}'
    printf 'LUNS='
    ioreg -c IOBlockStorageServices 2>/dev/null | grep -c 'USB3.0 DISK'
    printf 'SERIALS='
    ls /var/run/disk/by-serial/ 2>/dev/null | grep -c '^USB30_DISK0[01]-.*C3$'
}

echo "=== watch started $(date '+%F %T') ===" >> "$LOG"
prev=''
while :; do
    cur=$(fingerprint)
    if [ "$cur" != "$prev" ]; then
        {
            echo
            echo "######## CHANGE at $(ts) ########"
            echo "--- zpool status -v ---"
            zpool status -v tank 2>&1
            echo "--- by-serial present ---"
            ls /var/run/disk/by-serial/ 2>/dev/null | grep '^USB30_DISK' || echo '(none)'
            echo "--- SCSI LUNs present ---"
            ioreg -c IOBlockStorageServices 2>/dev/null \
                | grep -oE 'USB3\.0 DISK0[01]' | sort -u || echo '(none)'
            echo "--- zpool events (last 12) ---"
            zpool events tank 2>&1 | tail -12
            echo "--- new zed log lines ---"
            newsize=$(wc -c < "$ZEDLOG" 2>/dev/null || echo 0)
            if [ "$newsize" -gt "$zed_off" ]; then
                tail -c +$((zed_off + 1)) "$ZEDLOG" 2>/dev/null | tail -40
                zed_off=$newsize
            else
                echo '(no new zed output)'
            fi
        } >> "$LOG" 2>&1
        prev=$cur
    fi
    sleep 2
done
