#!/bin/sh
#
# copyparty-server.sh — serve tank/documents with copyparty, the Dropbox
# replacement. Same shape as jellyfin-server.sh: guard, then `exec` the server
# so launchd supervises it directly. launchd (KeepAlive) restarts it.
#
# ---------------------------------------------------------------------------
# Why copyparty, not Seafile (decided 2026-11-08):
#   - Seafile's server is Docker-only since 13.0, and Docker Desktop here is a
#     login item. No auto-login means no Seafile after an unattended reboot.
#   - Seafile stores libraries as content-addressed blocks. Snapshots, tankbak
#     and the S3 offsite would back up chunks only Seafile can reassemble.
#   copyparty is one Python program from Homebrew, runs as a LaunchDaemon, and
#   writes plain files, so every existing protection layer covers uploads as-is.
#   Phones upload through the Party UP! Android app (F-Droid) share menu.
#
# ---------------------------------------------------------------------------
# Why the guard matters here (different from Jellyfin's reason):
# tank/my_media is served too (read-only), so an unmounted one would show as
# an empty folder rather than an error; it is waited for as well. For
# documents the stakes are higher: with the pool absent, /Volumes/tank/documents is either missing or an empty
# directory on the boot SSD. An upload in that state would land on the SSD,
# outside snapshots and backups, and the leftover files would then make the
# real dataset fail to mount over a non-empty directory. So: no healthy,
# mounted tank/documents, no server.
#
# The health check precedes the mount check because `failmode=wait` makes
# anything touching a SUSPENDED pool hang uninterruptibly; `zpool list` answers.
#
# Runs as fabigato (UserName in the plist): tank/documents is fabigato:staff,
# and root is wrong for a network-facing server.
#
# Exit codes:  1 = refused (pool absent, unhealthy, or dataset not mounted)
#              2 = install problem (missing binary, config, or state dir)
# On success this script does not exit; it becomes the server.

set -u

ZPOOL=/usr/local/zfs/bin/zpool
ZFS=/usr/local/zfs/bin/zfs

POOL=tank
# dataset:mountpoint pairs. Every one must be mounted where expected.
DATASETS="tank/documents:/Volumes/tank/documents tank/my_media:/Volumes/tank/my_media"

CPP_BIN=/opt/homebrew/bin/copyparty
CPP_ROOT=/usr/local/var/copyparty
CPP_CONF="$CPP_ROOT/copyparty.conf"
CPP_ACCOUNTS="$CPP_ROOT/accounts.conf"
CPP_HIST="$CPP_ROOT/hist"
CPP_LOGDIR=/var/log/copyparty

LOG=/var/log/copyparty-server.log

# Longer than the boot unlock's own 120 s poll, as in jellyfin-server.sh: both
# start together at boot and the unlock has to finish first.
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
# `brew upgrade copyparty` can move its Python; a broken symlink should be one
# log line, not a silent restart loop.
[ -x "$CPP_BIN" ]      || fail "copyparty missing: $CPP_BIN (brew uninstalled it?)" 2
[ -r "$CPP_CONF" ]     || fail "config missing: $CPP_CONF" 2
[ -r "$CPP_ACCOUNTS" ] || fail "accounts missing: $CPP_ACCOUNTS (run make-accounts.sh)" 2

for d in "$CPP_ROOT" "$CPP_HIST" "$CPP_LOGDIR"; do
	[ -d "$d" ] || fail "state directory missing: $d (run the install steps)" 2
	[ -w "$d" ] || fail "state directory not writable by $(id -un): $d" 2
done

# --- wait for a healthy pool ----------------------------------------------
waited=0
while : ; do
	health=$("$ZPOOL" list -H -o health "$POOL" 2>/dev/null)

	if [ "$health" = "ONLINE" ] || [ "$health" = "DEGRADED" ]; then
		missing=
		for pair in $DATASETS; do
			ds=${pair%%:*}; want=${pair#*:}
			mounted=$("$ZFS" get -H -o value mounted "$ds" 2>/dev/null)
			mp=$("$ZFS" get -H -o value mountpoint "$ds" 2>/dev/null)
			if [ "$mounted" != "yes" ] || [ "$mp" != "$want" ]; then
				missing="$missing $ds(mounted=$mounted,mountpoint=$mp)"
			fi
		done
		[ -z "$missing" ] && break
		state="not mounted where expected:$missing"
	elif [ -z "$health" ]; then
		state="pool '$POOL' not imported"
	else
		state="pool '$POOL' is $health"
	fi

	if [ "$waited" -ge "$WAIT_SECS" ]; then
		fail "$state after ${WAIT_SECS}s — not starting copyparty, uploads \
would land on the boot SSD. launchd will retry."
	fi

	[ "$waited" -eq 0 ] && log "waiting: $state"
	sleep "$POLL_SECS"
	waited=$((waited + POLL_SECS))
done

[ "$waited" -gt 0 ] && log "pool ready after ${waited}s"
log "pool $POOL is $health, mounted:$(printf ' %s' $DATASETS)"

# --- become the server ----------------------------------------------------
log "exec $CPP_BIN -c $CPP_CONF"

# copyparty keeps a few dotfiles under HOME; pin it to the state tree.
HOME="$CPP_ROOT"; export HOME
cd "$CPP_ROOT" || fail "cannot cd to $CPP_ROOT" 2

exec "$CPP_BIN" -c "$CPP_CONF"

fail "exec failed" 2
