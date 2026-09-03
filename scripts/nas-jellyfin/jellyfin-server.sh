#!/bin/sh
#
# jellyfin-server.sh — run the Jellyfin media server against the `tank` pool.
#
# This is a supervisor wrapper, not a scheduled job. Unlike the scrub and
# snapshot daemons it does not run and exit; it guards, then `exec`s the server
# and stays alive for as long as Jellyfin does. launchd restarts it.
#
# ---------------------------------------------------------------------------
# Decision 1: the server binary, not the .app.
#
# Jellyfin ships on macOS only as `Jellyfin.app`, a menu-bar wrapper (its
# Info.plist carries LSUIElement=true) around the real .NET server. The wrapper
# is a LOGIN ITEM, and a login item is worthless here: this machine
# deliberately has no automatic login, so nothing in the user session exists
# until someone physically logs in at the console. That is the exact failure
# that left Tailscale down for 1h37m after the 2026-08-30 boot.
#
# So we ignore `Contents/MacOS/Jellyfin Server` (the Cocoa wrapper) and run
# `Contents/MacOS/jellyfin` (the server) directly from a LaunchDaemon, with
# `--service` for headless operation. Same shape as the tailscaled migration.
#
# The app bundle is still the install mechanism — `brew install --cask jellyfin`
# — because it is where the server binary and jellyfin-ffmpeg come from. It is
# a payload directory here, not an application.
#
# ---------------------------------------------------------------------------
# Decision 2: native, not Docker. (Settled 2026-08-23.)
#
# Docker on macOS runs containers in a Linux VM on Virtualization.framework and
# Apple's hypervisor exposes no GPU or media engine to guests — measured, there
# are no render nodes in the VM. A containerised Jellyfin can therefore only
# transcode in software, on a CPU already shared with comfyui and the local LLM
# stack. Running native buys the M4 Max media engine through VideoToolbox.
#
# Verified on this bundle: the shipped ffmpeg is built --enable-videotoolbox and
# offers h264_videotoolbox / hevc_videotoolbox encoders plus scale_vt and
# tonemap_videotoolbox filters.
#
# ---------------------------------------------------------------------------
# Decision 3: refuse to start when the pool is not there.
#
# This is the guard that matters, and it protects data rather than uptime.
# Jellyfin treats a library path that has gone missing as a library that has
# been EMPTIED: a scan against an unmounted /Volumes/tank would remove every
# item from its database, taking watch state, playlists and user data with it.
# The media survives — the metadata does not.
#
# So the wrapper polls for a healthy, mounted pool and exits nonzero rather than
# letting the server come up blind. With KeepAlive in the plist, launchd retries
# every ThrottleInterval, which means the server heals itself the moment the
# enclosure is switched back on — pairing with the WatchPaths arrival trigger on
# local.tank-boot-unlock rather than duplicating it.
#
# The health check runs BEFORE the mount check on purpose. `failmode=wait` means
# anything touching a suspended pool hangs in an uninterruptible ioctl that
# SIGKILL cannot free, so we ask `zpool list` (which answers on a suspended
# pool) before asking anything that would touch a dataset.
#
# ---------------------------------------------------------------------------
# Decision 4: runs as fabigato, not root, not a service account.
#
# Root is wrong for a network-facing server that parses untrusted media files.
# A dedicated `_jellyfin` account was considered and rejected: it would need its
# own dscl provisioning, its own TCC grants against a removable volume, and
# perms changes on datasets owned fabigato:staff — a lot of new surface to buy a
# separation that the read-only posture already provides differently. See
# `tests/jellyfin-readonly/`, which asserts the server writes nothing to the
# media datasets rather than trusting POSIX to forbid it.
#
# ---------------------------------------------------------------------------
# Decision 5: every writable path is on the internal SSD.
#
# JF_ROOT lives under /usr/local/var, never on `tank`. Transcode scratch is the
# reason: it is large, short-lived, rewritten constantly, and both media
# datasets are snapshotted. Scratch on a snapshotted dataset is captured by the
# next snapshot and inflates `usedbysnapshots` with data nobody will ever want
# back. The same argument covers the database and the image cache, which would
# additionally put small random writes on a 1M-recordsize dataset.
#
# ---------------------------------------------------------------------------
# Exit codes:  1 = refused (pool absent, unhealthy, or datasets not mounted)
#              2 = install problem (missing binary or unwritable state dir)
# On success this script does not exit; it becomes the server.

set -u

ZPOOL=/usr/local/zfs/bin/zpool
ZFS=/usr/local/zfs/bin/zfs

POOL=tank
DATASETS="tank/media tank/my_media"

JF_APP=/Applications/Jellyfin.app/Contents
JF_BIN="$JF_APP/MacOS/jellyfin"
JF_FFMPEG="$JF_APP/MacOS/ffmpeg"
JF_WEB="$JF_APP/Resources/jellyfin-web"

JF_ROOT=/usr/local/var/jellyfin
JF_CONFIG="$JF_ROOT/config"
JF_DATA="$JF_ROOT/data"
JF_CACHE="$JF_ROOT/cache"
JF_LOGDIR=/var/log/jellyfin

# Not passed as a flag — it comes from TranscodingTempPath in encoding.xml —
# but checked here anyway. Jellyfin creates this directory itself at startup and
# its "Clean Transcode Directory" scheduled task deletes it again, so it has to
# stay re-creatable rather than merely existing. What it cannot do is create a
# missing PARENT it has no permission for: with /usr/local/var absent, startup
# dies with `UnauthorizedAccessException: Access to the path '/usr/local/var' is
# denied` from GetTranscodePath, several frames deep in a stack trace that says
# nothing about transcoding being misconfigured. Checking JF_ROOT for writability
# turns that into one line in this log.
JF_TRANSCODES="$JF_ROOT/transcodes"

LOG=/var/log/jellyfin-server.log

# How long to wait for the pool before giving up and letting launchd retry.
# Longer than the boot unlock's own 120 s poll, because at boot this daemon and
# local.tank-boot-unlock start together and the unlock's retries have to finish
# first. Overshooting costs nothing; undershooting means a restart loop at every
# cold boot.
WAIT_SECS=300
POLL_SECS=5

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

fail() {
	log "REFUSED: $*"
	exit "${2:-1}"
}

log "--- starting (pid $$, uid $(id -u), user $(id -un)) ---"

# --- install sanity -------------------------------------------------------
# Checked rather than assumed because `brew upgrade --cask jellyfin` replaces
# the whole bundle, and a rename inside it would otherwise show up as a restart
# loop with no explanation.
[ -x "$JF_BIN" ]    || fail "server binary missing: $JF_BIN (cask uninstalled?)" 2
[ -x "$JF_FFMPEG" ] || fail "bundled ffmpeg missing: $JF_FFMPEG" 2
[ -d "$JF_WEB" ]    || fail "web client missing: $JF_WEB" 2

for d in "$JF_ROOT" "$JF_CONFIG" "$JF_DATA" "$JF_CACHE" "$JF_LOGDIR"; do
	[ -d "$d" ] || fail "state directory missing: $d (run the install steps)" 2
	[ -w "$d" ] || fail "state directory not writable by $(id -un): $d" 2
done

# JF_ROOT above is what makes this recoverable rather than fatal: the transcode
# directory is deleted by a scheduled task and recreated on demand, so it is
# allowed to be absent right now.
[ -e "$JF_TRANSCODES" ] && [ ! -w "$JF_TRANSCODES" ] && \
	fail "transcode directory exists but is not writable: $JF_TRANSCODES" 2

# --- wait for a healthy pool ----------------------------------------------
waited=0
while : ; do
	health=$("$ZPOOL" list -H -o health "$POOL" 2>/dev/null)

	if [ "$health" = "ONLINE" ] || [ "$health" = "DEGRADED" ]; then
		# Only now is it safe to touch a dataset. A pool that is imported but
		# SUSPENDED would hang this next call forever, which is why the health
		# check gates it.
		missing=
		for ds in $DATASETS; do
			mounted=$("$ZFS" get -H -o value mounted "$ds" 2>/dev/null)
			[ "$mounted" = "yes" ] || missing="$missing $ds"
		done
		[ -z "$missing" ] && break
		state="datasets not mounted:$missing"
	elif [ -z "$health" ]; then
		state="pool '$POOL' not imported"
	else
		state="pool '$POOL' is $health"
	fi

	if [ "$waited" -ge "$WAIT_SECS" ]; then
		fail "$state after ${WAIT_SECS}s — not starting the server. Jellyfin \
treats a missing library path as an emptied library and would purge its \
database. launchd will retry."
	fi

	# One line per attempt would be a line every 5 s forever while the
	# enclosure is off. Log the first observation and then stay quiet.
	[ "$waited" -eq 0 ] && log "waiting: $state"
	sleep "$POLL_SECS"
	waited=$((waited + POLL_SECS))
done

[ "$waited" -gt 0 ] && log "pool ready after ${waited}s"
log "pool $POOL is $health, datasets mounted:$(printf ' %s' $DATASETS)"

# --- become the server ----------------------------------------------------
# exec, so launchd supervises Jellyfin itself rather than this shell. Without it
# launchd would watch a /bin/sh that has no idea whether its child is healthy,
# and KeepAlive would restart the wrapper instead of the server.
log "exec $JF_BIN"

HOME="$JF_DATA"; export HOME
# .NET writes ~/.dotnet and ~/.aspnet if left to itself; pinning HOME to the
# data dir keeps that inside the state tree instead of in /var/root or
# /Users/fabigato depending on who launchd decided we are.

exec "$JF_BIN" \
	--service \
	--nonetchange \
	-c "$JF_CONFIG" \
	-d "$JF_DATA" \
	-C "$JF_CACHE" \
	-l "$JF_LOGDIR" \
	-w "$JF_WEB" \
	--ffmpeg "$JF_FFMPEG"

# --nonetchange: this machine's interfaces do not change under it, and the
# network-change handler rebinds the listener — which on a loopback-only bind
# behind `tailscale serve` is all downside.
#
# --ffmpeg is passed explicitly rather than left to PATH. A LaunchDaemon gets a
# minimal PATH that does not include /opt/homebrew/bin, so "found in PATH" would
# resolve to Homebrew's ffmpeg or to nothing at all. The bundled build is the
# one with the VideoToolbox filters Jellyfin's hwaccel paths expect.

fail "exec failed" 2
