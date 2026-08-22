#!/bin/sh
#
# tank-scrub.sh — scheduled scrub of the encrypted pool `tank`.
#
# WHY THIS EXISTS, AND WHY IT IS NOT OPTIONAL
# SMART does not work through the Orico enclosure — smartmontools on macOS has
# no SCSI passthrough for USB mass storage, so there are no reallocated-sector
# counts and no power-on hours for these drives. That removes the usual early
# warning entirely. A scrub reads EVERY allocated block on both mirror members
# and verifies it against its checksum, rewriting anything that doesn't match
# from the good copy. It is therefore the only proactive health check this
# setup has. It detects corruption that already happened; it still gives no
# advance warning of a drive about to die.
#
# WHAT THIS SCRIPT IS AND ISN'T
# It is a scheduler with guards and a durable log. It is NOT the notifier:
# `zed` is already running with scrub_finish-notify.sh enabled, which is the
# right place for "tell me when a scrub found something". As shipped it has no
# delivery channel configured (ZED_EMAIL_ADDR=root with no MTA), so it notifies
# nobody — see the NOTIFICATIONS note at the bottom of this header.
#
# EXIT CODES — these are the summary, readable via
#   launchctl print system/local.tank-scrub | grep 'last exit'
#   0  scrub completed clean
#   1  preflight refused to start (pool missing, suspended, or unreadable)
#   2  scrub completed but something was repaired or errored — READ THE LOG
#   3  nothing to do (a scrub or resilver was already running)
#   4  gave up waiting for the scrub to finish; it is still running
#
# TESTING — kickstart, never a terminal, and never a reboot:
#   sudo launchctl kickstart -k system/local.tank-scrub
#   tail -f /var/log/tank-scrub.log
# A terminal run proves less than it looks like it does: sudo inherits the
# terminal app's Full Disk Access grant, which is exactly how the boot-unlock
# bug hid for three cold boots. This daemon should not need FDA at all — both
# `zpool scrub` and `zpool status` act on an already-imported pool through the
# /dev/zfs ioctl, so the kernel does the disk I/O and no raw device is opened —
# but that is a prediction, not a measurement. Verify it once:
#   /usr/bin/log show --last 5m --style compact | grep 'deny(1)'
# and expect zero hits for zpool.
#
# Testing is cheap RIGHT NOW and will not be later: the pool holds ~10 MB, so a
# full scrub finishes in seconds. At 5 TB of real data expect 10-20 hours over
# USB. Do the kickstart test before the pool fills up.
#
# Rollback: sudo launchctl bootout system/local.tank-scrub
#           sudo rm /Library/LaunchDaemons/local.tank-scrub.plist
#           sudo rm /usr/local/sbin/tank-scrub.sh
#           sudo rm /etc/newsyslog.d/tank.conf
# An in-flight scrub survives all of that, and survives reboots too — ZFS
# persists scan state in the pool. To stop one: sudo zpool scrub -s tank
#
# NOTIFICATIONS — the open end of this. A scrub that finds corruption and
# writes it only to a log file nobody reads has not monitored anything. zed's
# scrub_finish-notify.sh already builds the exact report you'd want and stays
# silent when the pool is healthy (ZED_NOTIFY_VERBOSE=0), so all that is
# missing is one channel in /etc/zfs/zed.d/zed.rc. zed-functions.sh in this
# build implements email, ntfy, Pushover, Gotify, Pushbullet and Slack. Email
# needs an MTA on this machine and is the worst option. Until a channel is set,
# treat `grep -E 'ERRORS|REFUSED' /var/log/tank-scrub.log` as the alerting.

set -u

ZPOOL=/usr/local/zfs/bin/zpool
POOL=tank

LOG=/var/log/tank-scrub.log
STATE=/var/log/tank-scrub.last

# Poll cadence while the scrub runs, and how often to actually write a progress
# line. A 20-hour scrub logging every 10 minutes is 120 lines of noise; hourly
# is enough to see it moving and to spot a stall.
#
# Overridable only so the kickstart test does not spend 10 minutes asleep while
# an empty pool's scrub finishes in under a second:
#   sudo launchctl setenv TANK_SCRUB_POLL_SECS 5   # then kickstart, then unsetenv
# Nothing in production sets these.
POLL_SECS=${TANK_SCRUB_POLL_SECS:-600}
PROGRESS_EVERY=${TANK_SCRUB_PROGRESS_EVERY:-3600}

# Hard cap on how long we sit watching. Generous: a full 7 TiB pool over this
# USB bridge is 10-20h, and a scrub competing with a Jellyfin transcode is
# slower still. Hitting this cap does NOT stop the scrub — it only stops us
# watching, and exits 4 so the truncated log has an explanation.
MAX_WAIT_SECS=172800

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Loud channel for things a human must see. Goes to the unified log so it is
# greppable next to the kernel's own ZFS messages, which is where you will be
# looking anyway if the pool is misbehaving.
alert() {
	log "$*"
	/usr/bin/logger -t tank-scrub -p daemon.err "$*"
}

# The one-line `scan:` summary from zpool status. This is the whole progress and
# result story; there is no zpool property that exposes it, so it gets parsed.
scan_line() {
	"$ZPOOL" status "$POOL" 2>/dev/null | awk '/^  scan:/{sub(/^  scan: /,""); print; exit}'
}

# Error counters for the pool as a whole. Read from the pool's own row rather
# than summing the config block: ZFS already aggregates child counters upward,
# so summing every row would count each error three times over on this layout.
# -p keeps them exact integers instead of "1.20K".
counters() {
	"$ZPOOL" status -p "$POOL" 2>/dev/null | awk -v p="$POOL" '
		/^config:/ { in_config = 1; next }
		/^errors:/ { in_config = 0 }
		in_config && $1 == p { print $3, $4, $5; exit }
	'
}

log "--- start (pid $$) ---"

# ---------------------------------------------------------------------------
# 1. Preflight. The point of these guards is that a scheduled job must not
#    wedge or make things worse; skipping a month of scrubbing is recoverable,
#    a hung daemon holding the pool is less so.
# ---------------------------------------------------------------------------

if ! "$ZPOOL" list -H -o name "$POOL" >/dev/null 2>&1; then
	alert "REFUSED: pool $POOL is not imported. Nothing to scrub."
	log "      This is itself the problem — tank should always be imported."
	log "      Check /var/log/tank-boot-unlock.log first; that daemon owns import."
	exit 1
fi

health=$("$ZPOOL" list -H -o health "$POOL" 2>/dev/null)
case "$health" in
ONLINE)
	log "health: ONLINE"
	;;
DEGRADED)
	# Scrub anyway, deliberately. A degraded mirror still has one good copy and
	# verifying it is worth more than usual, not less. But say so loudly,
	# because on THIS hardware a degraded state is remarkable: the 2026-08-17
	# pull test showed a removed drive does not produce DEGRADED at all — the
	# JMicron bridge drops both LUNs and the pool suspends instead. So DEGRADED
	# here means a genuine per-device fault the bridge survived, which is a
	# failure mode never yet observed on this setup.
	alert "health: DEGRADED — scrubbing anyway, but investigate. See zpool status -v."
	;;
*)
	# SUSPENDED / UNAVAIL / empty. failmode is deliberately `wait`, so any
	# process that touches a suspended pool hangs rather than erroring. Issuing
	# a scrub here would produce exactly that: a daemon blocked in an
	# uninterruptible ioctl, which SIGKILL will not free. Refuse instead.
	# Reading state is safe — measured during the pull test, zpool status kept
	# answering with a drive physically removed.
	alert "REFUSED: pool health is '${health:-<unreadable>}', not ONLINE or DEGRADED."
	log "      Not issuing a scrub: failmode=wait means it would block forever in"
	log "      the ioctl, and SIGKILL does not free an uninterruptible sleep."
	log "      A suspended pool is a bridge fault, not a scrub problem. Recovery is"
	log "      one command once the devices are back: sudo zpool clear $POOL"
	log "      See the drive-pull test writeup in ~/repos/nas/tests/."
	exit 1
	;;
esac

before=$(scan_line)
log "last scan: ${before:-<none recorded>}"

case "$before" in
*"in progress"*)
	# Covers both a scrub still running from last month and a resilver. Starting
	# a second scan is an error from zpool anyway; exiting 3 makes the skip
	# legible in `launchctl print` instead of looking like a failure.
	alert "SKIP: a scan is already in progress — leaving it alone."
	log "      $before"
	exit 3
	;;
esac

read_before=$(counters)
log "counters before (read write cksum): ${read_before:-<unreadable>}"
if [ "$read_before" != "0 0 0" ] && [ -n "$read_before" ]; then
	# Counters are cumulative until `zpool clear`, so a nonzero baseline is
	# almost certainly last month's unacknowledged problem rather than a new
	# one. Never clear them automatically: that would erase the only evidence a
	# human has not yet looked at. The delta below is what makes this scrub's
	# own findings readable despite the stale baseline.
	alert "NOTE: error counters were already nonzero BEFORE this scrub ($read_before)."
	log "      Cumulative since the last 'zpool clear'. Not cleared automatically —"
	log "      that would destroy evidence. Acknowledge, then: sudo zpool clear $POOL"
fi

# ---------------------------------------------------------------------------
# 2. Start the scrub. Returns immediately; the scan runs in the kernel.
# ---------------------------------------------------------------------------

started=$(date +%s)
out=$("$ZPOOL" scrub "$POOL" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
	alert "FAIL: zpool scrub exited $rc: ${out:-<no output>}"
	exit 1
fi
log "scrub started"

# Not using `zpool scrub -w`, which this build supports. -w blocks in the ioctl
# until the scan finishes, which buys nothing here and costs two things that
# matter: no progress line for a job that can run 20 hours, and no way to stop
# waiting on our own terms. Polling is a few more lines and stays in control.

# ---------------------------------------------------------------------------
# 3. Watch it. Note that neither this loop nor this process is load-bearing:
#    the scan lives in the kernel and survives us being killed, and survives a
#    reboot. Everything below is observation.
# ---------------------------------------------------------------------------

# Sleep first, check second. Sidesteps any question about whether the `scan:`
# line is already populated the instant the scrub ioctl returns — by the first
# check it certainly is.
last_progress=0
while :; do
	sleep "$POLL_SECS"
	elapsed=$(($(date +%s) - started))
	line=$(scan_line)

	case "$line" in
	*"in progress"*) ;;
	*)
		break
		;;
	esac

	# A bridge fault mid-scrub is the realistic bad outcome, and it looks like a
	# scan that stops advancing forever. Bail out rather than sit here for two
	# days pretending to monitor.
	health=$("$ZPOOL" list -H -o health "$POOL" 2>/dev/null)
	if [ "$health" != "ONLINE" ] && [ "$health" != "DEGRADED" ]; then
		alert "ABORT WATCH: pool went to '${health:-<unreadable>}' mid-scrub after ${elapsed}s."
		log "      This is the bridge-fault signature, not a scrub failure."
		log "      The scan is still queued in the kernel and will resume if the pool"
		log "      recovers. Recovery: sudo zpool clear $POOL"
		exit 1
	fi

	if [ $((elapsed - last_progress)) -ge "$PROGRESS_EVERY" ]; then
		log "  ${elapsed}s: $line"
		last_progress=$elapsed
	fi

	if [ "$elapsed" -ge "$MAX_WAIT_SECS" ]; then
		alert "GIVING UP WATCHING after ${elapsed}s — the scrub is STILL RUNNING."
		log "      Not an error and not stopped; only this log ends here."
		log "      Follow it by hand: zpool status $POOL"
		log "      If it is genuinely stalled rather than slow, compare two"
		log "      'scanned at' figures a few minutes apart before concluding."
		exit 4
	fi
done

elapsed=$(($(date +%s) - started))
after=$(scan_line)
read_after=$(counters)

log "scan: $after"
log "counters after (read write cksum): ${read_after:-<unreadable>}"
log "watched for ${elapsed}s"
echo "$(date '+%Y-%m-%d %H:%M:%S') $after" >"$STATE"

# ---------------------------------------------------------------------------
# 4. Verdict. Three independent signals, because any one of them alone can look
#    fine while another does not: the scan summary (what this scrub did), the
#    error counters (I/O trouble, which a scrub can hit without repairing
#    anything), and `status -x` (whether ZFS itself considers the pool healthy,
#    including permanent unrecoverable files).
# ---------------------------------------------------------------------------

problem=

case "$after" in
*"with 0 errors"*) ;;
*"canceled"*)
	# Someone ran `zpool scrub -s`, or a reboot interrupted it. Worth a line,
	# not an alarm.
	log "RESULT: scrub was canceled before finishing — no verdict this run."
	log "--- done ---"
	exit 0
	;;
*)
	problem="scan summary reports errors"
	;;
esac

case "$after" in
*"repaired 0B"*) ;;
*)
	# Repaired means it found bad blocks and fixed them from the mirror. The data
	# is fine; the drive that produced them is the question.
	problem="${problem:+$problem; }blocks were repaired"
	;;
esac

if [ "$read_after" != "$read_before" ]; then
	problem="${problem:+$problem; }error counters moved during the scrub ($read_before -> $read_after)"
fi

xout=$("$ZPOOL" status -x "$POOL" 2>&1)
case "$xout" in
*"is healthy"*) ;;
*)
	problem="${problem:+$problem; }zpool status -x does not report healthy"
	;;
esac

if [ -n "$problem" ]; then
	alert "ERRORS: $problem"
	log "full status follows:"
	"$ZPOOL" status -v "$POOL" >>"$LOG" 2>&1
	log "      What to do, in order:"
	log "      1. 'errors:' above — a list of files means permanent, unrecoverable"
	log "         loss in those files specifically; restore them from backup."
	log "      2. Which member moved. There is no SMART here, so zpool status is"
	log "         the only map from a bad member to a physical bay; the by-serial"
	log "         names in the config block are that map."
	log "      3. Repeated CKSUM on one member across two scrubs is that drive"
	log "         dying. Spread evenly across both is more likely the bridge,"
	log "         the cable or the PSU — this enclosure is one JMicron bridge in"
	log "         front of both members."
	log "      4. Only after acknowledging: sudo zpool clear $POOL"
	log "--- done ---"
	exit 2
fi

log "RESULT: clean — no errors, nothing repaired, counters unchanged."
log "--- done ---"
exit 0
