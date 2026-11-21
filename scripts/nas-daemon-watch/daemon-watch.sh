#!/bin/sh
#
# daemon-watch.sh — notice when one of this machine's always-on services is
# dead, instead of finding out hours later by trying to use it.
#
# Runs every CHECK_EVERY seconds from local.daemon-watch (StartInterval), as
# root, and exits. It changes nothing: it probes, decides, notifies.
#
# ---------------------------------------------------------------------------
# Why it exists
#
# On 2026-11-20 the macOS 27.2.1 update swept /var/log. All three non-root
# daemons on this box -- local.jellyfin, local.copyparty and com.local.llmster
# -- failed to spawn with EX_CONFIG (78) at 15:56:28, because launchd opens
# StandardOutPath as the job's user before exec and could not recreate a file in
# a root-owned /var/log. Nothing was logged, because the thing that failed was
# the opening of the log. KeepAlive retried in silence ~3500 times each.
#
# Jellyfin and copyparty were noticed ~28 h later, by someone trying to watch
# something. The LM Studio daemon was missed in that pass and ran to 29 h: every
# agent, Open WebUI, Hindsight, Codex and the public endpoint dead, with no
# alert anywhere. The logging bug is fixed (see nas_log, "Logs out of /var/log
# entirely"), but the reason it lasted a day is this: nothing watched.
#
# ---------------------------------------------------------------------------
# Decision 1: the probe is the verdict, launchd is the explanation.
#
# "Is the port answering" is what a user actually experiences, and it catches
# failures launchd is happy about. Measured 2026-11-09: llmster's model worker
# died while llmster itself stayed up, so `launchctl print` read healthy for
# 2.5 h while every client got "No models loaded". A launchd-only check would
# have said nothing.
#
# So: the HTTP probe decides up or down. `launchctl print` and the unified log
# are read only to put a reason in the alert -- "job state = spawn failed",
# "last exit code = 78", and launchd's own message, which for the outage above
# is the one line that explains everything:
#   Unable to open stdout path (...), error 0xd - Permission denied
#
# ---------------------------------------------------------------------------
# Decision 2: two consecutive failures before alerting.
#
# Jellyfin takes ~15 s to start (9 s of it ffmpeg capability probing), llmster
# ~25 s to load 22 GiB of weights, and the watchdog inside llmster-server.sh
# reloads the model on purpose now and then. One missed probe is normal during
# any of that. Two in a row, CHECK_EVERY apart, is not.
#
# The cost of that choice is up to 2 x CHECK_EVERY of silence before the first
# alert. At 300 s that is ~10 minutes, against the 29 h it replaces.
#
# ---------------------------------------------------------------------------
# Decision 3: one alert per outage, plus a recovery line, plus a heartbeat.
#
# A message every 5 minutes for a day trains you to ignore the channel, so each
# service alerts once when it goes down and once when it comes back. The state
# lives in STATEDIR, one file per service.
#
# And a heartbeat every HEARTBEAT_SECS saying what is up, because a channel that
# only ever speaks on failure is indistinguishable from a broken channel. Same
# reasoning as tank-snapshot's monthly summary; weekly here, since this one is
# the alarm for everything else.
#
# ---------------------------------------------------------------------------
# Decision 4: it cannot be killed by its own logging.
#
# local.daemon-watch names no StandardOutPath, and this script creates its log
# directory itself and guards the redirect. That is the whole lesson of the
# outage it exists for, and it would be absurd for the watchman to die of it.
#
# It runs as root -- not for launchctl (a plain user can read `launchctl print
# system/...`) but because the webhook URL lives in zed.rc, mode 0600 root.

set -u

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# Services to watch: <launchd domain>|<label>|<human name>|<probe url>|<must contain>
#
# "must contain" is grepped against the probe's body, for an endpoint that
# answers 200 while being useless. Empty means any 2xx counts. Add a service by
# adding a line; nothing else in the script knows the list.
#
# Not listed: the periodic root daemons (tank-scrub, tank-snapshot,
# tank-offsite, hermes-backup). They are not always-on, they report their own
# verdicts to this same channel, and "is it running" is the wrong question for a
# job that is supposed to be absent. Their gap is a missed *schedule*, which is
# a different check and not built. Whisper (com.local.whisper-server, a user
# LaunchAgent on :8901) is a candidate but is not always-on in the same way.
# The last field is a ;-separated list of substrings that must ALL appear in the
# response body with its whitespace removed, so JSON pretty-printing does not
# matter. Kept short on purpose: a long exact-shape match would turn an LM
# Studio update that reorders a field into a false alarm, and a false alarm in
# the one channel that reports real failures is worse than a missed field.
#
# The three for LM Studio are each one of its past failures. "id" is the alias
# clients ask for, which a JIT load cannot create; "state":"loaded" is the
# 2026-11-09 case where the model worker died while llmster stayed up and
# launchd stayed happy; the context length is the JIT load that comes back at
# 8192 and breaks OpenClaw with "tokens to keep ... greater than the context
# length". /api/v0/models rather than /v1/models because only the former
# reports load state at all -- /v1/models lists everything downloaded and would
# have answered 200 through every one of those failures.
WATCH='system|local.jellyfin|Jellyfin|http://127.0.0.1:8096/health|Healthy
system|local.copyparty|copyparty|http://127.0.0.1:3923/|
system|com.local.llmster|LM Studio|http://127.0.0.1:1234/api/v0/models|"id":"qwen3.8-27b";"state":"loaded";"loaded_context_length":262144'

CHECK_EVERY=${DAEMON_WATCH_EVERY:-300}          # must match StartInterval
FAILS_BEFORE_ALERT=${DAEMON_WATCH_FAILS:-2}
PROBE_TIMEOUT=${DAEMON_WATCH_PROBE_TIMEOUT:-10}
HEARTBEAT_SECS=${DAEMON_WATCH_HEARTBEAT_SECS:-604800}   # 7 days

LOGDIR=${DAEMON_WATCH_LOGDIR:-/usr/local/var/log/daemon-watch}
LOG="$LOGDIR/watch.log"
STATEDIR=${DAEMON_WATCH_STATE:-/usr/local/var/daemon-watch}
HEARTBEAT="$STATEDIR/heartbeat"

ZEDRC=${DAEMON_WATCH_ZEDRC:-/etc/zfs/zed.d/zed.rc}
NOTIFY_MAX_CHARS=1500
DRY_RUN=${DAEMON_WATCH_DRY_RUN:-0}

# --- our own logging, before anything that logs -------------------------------
# Created here, never by launchd: see Decision 4.
mkdir -p "$LOGDIR" "$STATEDIR" 2>/dev/null
if : >>"$LOG" 2>/dev/null; then
	exec >>"$LOG" 2>&1
fi

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Push a message to whatever channel zed is configured for, reusing zed's own
# webhook URL so delivery is configured in exactly one place.
#
# This is deliberately a copy of tank-snapshot.sh's notify() rather than a
# shared sourced library, for the reason written out there: independent failure
# domains, and a syntax error in a common file would take every daemon with it.
# The URL is READ, not sourced. It must end in /slack, Discord's
# Slack-compatible endpoint; without that suffix it fails SILENTLY (HTTP 400
# reported as delivered), which is why the HTTP status is checked here rather
# than trusting curl's exit code.
#
# $1 = subject, $2 = body.
notify() {
	if [ "$DRY_RUN" = 1 ]; then
		log "  notify: DRY RUN, not sent: [$1] $2"
		return 0
	fi

	nurl=$(awk -F'"' '/^ZED_SLACK_WEBHOOK_URL=/ { print $2; exit }' "$ZEDRC" 2>/dev/null)
	if [ -z "$nurl" ]; then
		log "  notify: no channel set (ZED_SLACK_WEBHOOK_URL in $ZEDRC) — log only"
		return 0
	fi

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
		log "          URL in $ZEDRC, and that this machine has network."
		;;
	esac
}

# Everything launchd will tell us about a job, as one line, for the alert body.
# Absent or unloadable is itself the answer.
launchd_state() {
	_out=$(launchctl print "$1/$2" 2>/dev/null) || {
		printf 'not loaded in %s' "$1"
		return
	}
	printf '%s' "$_out" | awk '
		/^[ \t]+state = /          { gsub(/^[ \t]+/, ""); s = $0 }
		/^[ \t]+pid = /            { gsub(/^[ \t]+/, ""); p = $0 }
		/^[ \t]+runs = /           { gsub(/^[ \t]+/, ""); r = $0 }
		/^[ \t]+last exit code = / { gsub(/^[ \t]+/, ""); e = $0 }
		/job state = /             { gsub(/^[ \t]+/, ""); j = $0 }
		END { printf "%s", s; if (p) printf ", %s", p; if (r) printf ", %s", r;
		      if (e) printf ", %s", e; if (j) printf ", %s", j }'
}

# launchd's own last word about this label, which for a spawn failure is the
# only place the reason exists at all.
launchd_why() {
	log show --predicate "eventMessage CONTAINS \"$1\"" --last 30m --style compact 2>/dev/null |
		grep -i "launchd" | grep -iE "could not|unable|failed|denied" | tail -2
}

# 0 = healthy. Writes the reason to stdout when it is not.
#
# The body goes to a file in our own state directory rather than through a
# variable, so that a megabyte of HTML from a confused server cannot be held in
# memory and mangled by command substitution, and rather than mktemp so this has
# no opinion about TMPDIR as a root job.
probe() {
	_label=$1
	_url=$2
	_want=$3
	[ -z "$_url" ] && return 0          # launchd-state-only service

	_bodyfile="$STATEDIR/.probe.$_label.$$"
	_code=$(curl -sS --max-time "$PROBE_TIMEOUT" -o "$_bodyfile" -w '%{http_code}' "$_url" 2>/dev/null)

	case "$_code" in
	2*) ;;
	*)
		rm -f "$_bodyfile"
		printf 'probe %s returned %s' "$_url" "${_code:-no response}"
		return 1
		;;
	esac

	if [ -n "$_want" ]; then
		_flat=$(tr -d ' \t\n\r' <"$_bodyfile" 2>/dev/null)
		_oldifs=$IFS
		IFS=';'
		for _w in $_want; do
			case "$_flat" in
			*"$_w"*) ;;
			*)
				IFS=$_oldifs
				rm -f "$_bodyfile"
				printf 'probe %s answered %s but is missing %s' "$_url" "$_code" "$_w"
				return 1
				;;
			esac
		done
		IFS=$_oldifs
	fi
	rm -f "$_bodyfile"
	return 0
}

now=$(date +%s)
host=$(hostname -s)
alerted_now=0
up_list=""
down_list=""

printf '%s\n' "$WATCH" | while IFS='|' read -r domain label name url want; do
	[ -z "${label:-}" ] && continue

	statefile="$STATEDIR/$label"
	fails=0
	notified=0
	if [ -f "$statefile" ]; then
		# "<consecutive failures> <1 if an alert was already sent>"
		read -r fails notified <"$statefile" 2>/dev/null || true
		fails=${fails:-0}
		notified=${notified:-0}
	fi

	if reason=$(probe "$label" "$url" "$want"); then
		# Healthy. Say so once if we had complained.
		if [ "$notified" = 1 ]; then
			log "$name RECOVERED after $fails failed checks"
			notify "daemon-watch: $name recovered on $host" \
"$name is answering again.

launchd: $(launchd_state "$domain" "$label")"
		elif [ "$fails" -gt 0 ]; then
			log "$name healthy again (had $fails failed check(s), never alerted)"
		fi
		printf '0 0\n' >"$statefile"
		printf '%s\n' "UP   $name" >>"$STATEDIR/.summary.$$"
		continue
	fi

	fails=$((fails + 1))
	log "$name DOWN ($fails/$FAILS_BEFORE_ALERT): $reason"
	printf '%s\n' "DOWN $name — $reason" >>"$STATEDIR/.summary.$$"

	if [ "$fails" -ge "$FAILS_BEFORE_ALERT" ] && [ "$notified" != 1 ]; then
		lstate=$(launchd_state "$domain" "$label")
		why=$(launchd_why "$label")
		log "  alerting. launchd: $lstate"
		notify "daemon-watch: $name is DOWN on $host" \
"$reason
(failed $fails checks ${CHECK_EVERY}s apart)

launchd: $lstate
${why:+
launchd said:
$why}
Log: $LOG"
		notified=1
	fi
	printf '%s %s\n' "$fails" "$notified" >"$statefile"
done

# The loop above runs in a subshell (the pipe), so the summary comes back
# through a file rather than through variables.
summary=$(cat "$STATEDIR/.summary.$$" 2>/dev/null | sort)
rm -f "$STATEDIR/.summary.$$"
down_count=$(printf '%s\n' "$summary" | grep -c '^DOWN' || true)

log "checked $(printf '%s\n' "$summary" | grep -c . || true) service(s), $down_count down"

# Heartbeat: proof the channel still works, only when nothing is wrong.
if [ "$down_count" -eq 0 ]; then
	hb_age=$HEARTBEAT_SECS
	if [ -f "$HEARTBEAT" ]; then
		hb=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
		hb_age=$((now - ${hb:-0}))
	fi
	if [ "$hb_age" -ge "$HEARTBEAT_SECS" ]; then
		log "heartbeat due (last was ${hb_age}s ago)"
		notify "daemon-watch: all services up on $host" \
"$summary

Nothing has been down since the last heartbeat.
This message is the proof that this channel still works; if it stops arriving,
daemon-watch itself is dead."
		printf '%s\n' "$now" >"$HEARTBEAT"
	fi
fi

exit 0
