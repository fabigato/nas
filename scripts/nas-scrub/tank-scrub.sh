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
# It is a scheduler with guards, a durable log, and alerting for its OWN
# failures. It is not the scrub-result reporter: `zed` owns that via
# scrub_finish-notify.sh, which builds a better report than anything worth
# writing here.
#
# The split is about who can see what. zed only ever speaks when a scrub
# FINISHES. It is structurally silent about the cases where the scrub never ran
# at all — pool not imported, pool suspended, preflight refused, watch aborted
# — and those are exactly the cases where silence is most misleading, because
# "healthy" and "never ran" look identical from outside. So this script alerts
# on its own refusals and aborts, and leaves the clean-scrub report to zed.
# See the NOTIFICATIONS note at the bottom of this header.
#
# EXIT CODES — these are the summary, readable via
#   launchctl print system/local.tank-scrub | grep 'last exit'
#   0  scrub completed clean
#   1  preflight refused to start (pool missing, suspended, or unreadable)
#   2  scrub completed but something was repaired or errored — READ THE LOG
#   3  nothing to do (a scrub or resilver was already running)
#   4  gave up waiting for the scrub to finish; it is still running
#
# TESTING — kickstart, never a terminal, and never a reboot. Use the test plist
# next to this script, which is the same program with a 5-second poll:
#   sudo launchctl bootstrap system /Library/LaunchDaemons/local.tank-scrub-test.plist
#   sudo launchctl kickstart -k system/local.tank-scrub-test
#   tail -f /var/log/tank-scrub.log
#   sudo launchctl bootout system/local.tank-scrub-test   # do not skip this
# Kickstarting local.tank-scrub itself works too and is just as valid a test —
# it only means waiting out one 600s poll before it notices the scrub finished.
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
# NOTIFICATIONS — Discord, via zed's Slack backend. Configured 2026-08-23.
#
# Discord webhooks expose a Slack-compatible endpoint: append /slack to the
# webhook URL and it accepts Slack's payload, which is what zed sends. So
# ZED_SLACK_WEBHOOK_URL in /etc/zfs/zed.d/zed.rc drives both zed and the
# notify() function below, one value, no Discord-specific code. Verified
# end to end 2026-08-23: HTTP 200, body "ok".
#
# ZED_NOTIFY_VERBOSE IS DELIBERATELY 1, against the default. It means a CLEAN
# scrub also posts, roughly twelve messages a year. The reason is not that a
# clean result is interesting — it is that the webhook can die without telling
# anyone (see notify() below for the measurement), so "no news is good news"
# is not a safe reading. With verbose on, the monthly message is a heartbeat:
# nothing arriving on the 1st is itself the signal. Turning this off means
# trusting silence, and silence here is ambiguous.
#
# Residual hole, stated so it is not mistaken for covered: if this daemon is
# unloaded, or the plist is removed, nothing notifies — neither zed nor this
# script runs at all. Only something outside the machine can catch that. A
# calendar reminder to glance at the log after the 1st is the cheap version.
#
# The webhook URL is a bearer credential: anyone holding it can post to the
# server. zed.rc should be chmod 600, and the URL escrowed in pass next to
# nas/tank-key. Regenerate it in Discord if it leaks.

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
# an empty pool's scrub finishes in under a second. Set them via
# EnvironmentVariables in local.tank-scrub-test.plist, NOT via
#   sudo launchctl setenv TANK_SCRUB_POLL_SECS 5
# which fails with "150: Operation not permitted while System Integrity
# Protection is engaged" — it mutates launchd's global environment and SIP
# forbids that. Measured 2026-08-22. Nothing in production sets these.
POLL_SECS=${TANK_SCRUB_POLL_SECS:-600}
PROGRESS_EVERY=${TANK_SCRUB_PROGRESS_EVERY:-3600}

# Hard cap on how long we sit watching. Generous: a full 7 TiB pool over this
# USB bridge is 10-20h, and a scrub competing with a Jellyfin transcode is
# slower still. Hitting this cap does NOT stop the scrub — it only stops us
# watching, and exits 4 so the truncated log has an explanation.
MAX_WAIT_SECS=172800

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Overridable for the same reason as POLL_SECS: so the delivery path can be
# tested against a throwaway config without editing the live one.
ZEDRC=${TANK_SCRUB_ZEDRC:-/etc/zfs/zed.d/zed.rc}
NOTIFY_MAX_CHARS=1500

# Push a message to whatever channel zed is configured for, reusing zed's own
# webhook URL so delivery is configured in exactly one place.
#
# WHY THIS DOES NOT CALL zed_notify(), which is sourceable and would be less
# code: zed's Slack backend cannot detect its own failure against Discord.
# Measured 2026-08-23 — POST to a webhook with a bad token returns
#   HTTP 401  {"message": "Invalid Webhook Token", "code": 50027}
# curl exits 0 because zed does not pass -f, and zed's error check greps for
# Slack's {"error": ... "message": ...} shape, which does not match Discord's
# flat {"message": ...}. So zed logs a rejected post as delivered. For the one
# channel that reports the daemon's own failures, that is exactly backwards, so
# this checks the HTTP status itself and says so in the log when delivery fails.
#
# The URL is READ, not sourced — no executing a config file from inside the
# daemon, and no chance of zed.rc clobbering a variable in here. It must end in
# /slack: that is Discord's Slack-compatible endpoint, and zed needs the same
# suffix, so one value serves both.
#
# $1 = subject, $2 = body.
notify() {
	nurl=$(awk -F'"' '/^ZED_SLACK_WEBHOOK_URL=/ { print $2; exit }' "$ZEDRC" 2>/dev/null)
	if [ -z "$nurl" ]; then
		log "  notify: no channel set (ZED_SLACK_WEBHOOK_URL in $ZEDRC) — log only"
		return 0
	fi

	# Same escaping zed uses, so the payload shape stays identical to what the
	# zedlets send. Truncated because Discord rejects a message body over 2000
	# characters with a 400 — and the bodies most likely to overflow are
	# `zpool status -v` with a long list of corrupted files, i.e. precisely when
	# the message matters most. Better clipped than dropped; the log has it all.
	# `head -c` counts bytes, so it can cut a multi-byte character in half and
	# emit invalid UTF-8 inside the JSON. Tested 2026-08-23: Discord actually
	# accepts that and returns 200, but only because it is lenient — iconv -c
	# drops the incomplete sequence so we are not relying on that. Its stderr is
	# discarded: it warns about the very truncation we asked for.
	nbody=$(printf '%s' "$2" | head -c "$NOTIFY_MAX_CHARS" |
		iconv -c -f UTF-8 -t UTF-8 2>/dev/null | awk '
		{ ORS = "\\n" }
		{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t");
		  gsub(/\f/, "\\f"); gsub(/\r/, "\\r"); print }')
	npayload=$(printf '{"text": "*%s*\\n```%s```"}' "$1" "$nbody")

	nstatus=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
		-X POST "$nurl" \
		--header 'Content-Type: application/json' \
		--data-binary "$npayload" 2>/dev/null)
	nrc=$?

	case "$nstatus" in
	2*) log "  notify: delivered (HTTP $nstatus)" ;;
	*)
		log "  notify: DELIVERY FAILED (curl rc=$nrc, HTTP ${nstatus:-none})."
		log "          The message above exists ONLY in this log. Check the webhook"
		log "          URL in $ZEDRC, and that this machine has network at 03:00."
		;;
	esac
}

# Loud channel for things a human must see: the log, the unified log (greppable
# next to the kernel's own ZFS messages), and the notification channel.
#
# $1 = one-line summary. $2 = optional detail, added to the notification body;
# the log gets detail separately and in full.
alert() {
	log "$1"
	/usr/bin/logger -t tank-scrub -p daemon.err "$1"
	if [ "${2:-}" != "" ]; then
		notify "tank-scrub: $POOL on $(hostname -s)" "$1

$2"
	else
		notify "tank-scrub: $POOL on $(hostname -s)" "$1"
	fi
}

# The whole `scan:` block from zpool status, flattened to one line with " | "
# between parts. This is the entire progress and result story — there is no
# zpool property that exposes scan state, so it gets parsed.
#
# It MUST be the whole block, not just the `scan:` line. A completed scrub is
# one line, but a running one spans three, and only the continuation lines carry
# the numbers:
#   scan: scrub in progress since Sat Aug 22 23:41:16 2026
#         1.20T / 7.10T scanned at 500M/s, 800G / 7.10T issued at 300M/s
#         0B repaired, 11.27% done, 05:12:33 to go
# An earlier version took the first line only and stopped there, which meant the
# hourly progress line logged the same static "in progress since ..." string
# every hour for the entire scrub — useless for the one thing it exists to do,
# which is show movement and expose a stall. Found 2026-08-22.
#
# Continuation lines are indented 8 spaces; every sibling section (`config:`,
# `errors:`) starts at column 1 and every other `  xxx:` field is indented 2, so
# "8 spaces" is an exact terminator rather than a guess.
scan_summary() {
	"$ZPOOL" status "$POOL" 2>/dev/null | awk '
		/^  scan:/  { out = $0; sub(/^  scan: /, "", out); found = 1; next }
		found && /^        / { part = $0; sub(/^ +/, "", part); out = out " | " part; next }
		found       { exit }
		END         { if (found) print out }
	'
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

before=$(scan_summary)
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

# Expect this to block for ~20s before returning, even though the scan itself is
# asynchronous: measured 22s on 2026-08-22 (23:40:54 -> 23:41:16) on an idle
# pool. Same signature as the ~22s a warm `zpool import` sometimes takes — the
# drives are spun down or in standby and the command waits on them. Not a hang,
# and not something to add a timeout around.
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
	line=$(scan_summary)

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
after=$(scan_summary)
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
	alert "ERRORS: $problem" "$("$ZPOOL" status -v "$POOL" 2>&1)"
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
