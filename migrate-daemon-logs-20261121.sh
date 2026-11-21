#!/bin/sh
# One-off migration, 2026-11-21. SUPERSEDED the same day by
# migrate-daemon-logs-usrlocal-20261121.sh, which moves these logs out of
# /var/log altogether and takes the log paths out of the plists. Kept for the
# record; do not re-run it, it would put the files back under /var/log.
#
# Moves the jellyfin and copyparty launchd/wrapper logs out of /var/log itself
# and into directories owned by fabigato, so that launchd can recreate them
# after a /var/log sweep instead of failing to spawn with EX_CONFIG (78).
#
# Idempotent: safe to re-run.
set -eu

REPO=/Users/fabigato/repos/nas/scripts
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

say "creating fabigato-owned log directories"
install -d -o fabigato -g staff -m 755 /var/log/jellyfin-server /var/log/copyparty-server
ls -ld /var/log/jellyfin-server /var/log/copyparty-server

say "moving existing logs in, keeping their history"
for svc in jellyfin copyparty; do
	if [ -f "/var/log/${svc}-server.log" ]; then
		mv -v "/var/log/${svc}-server.log" "/var/log/${svc}-server/wrapper.log"
	fi
	if [ -f "/var/log/${svc}-server.launchd.log" ]; then
		mv -v "/var/log/${svc}-server.launchd.log" "/var/log/${svc}-server/launchd.log"
	fi
	for old in "/var/log/${svc}-server.log."*.bz2 "/var/log/${svc}-server.launchd.log."*.bz2; do
		[ -e "$old" ] || continue
		mv -v "$old" "/var/log/${svc}-server/"
	done
	chown -R fabigato:staff "/var/log/${svc}-server"
done

say "installing plists, wrappers and newsyslog configs"
install -o root -g wheel -m 644 "$REPO/nas-jellyfin/local.jellyfin.plist"      /Library/LaunchDaemons/local.jellyfin.plist
install -o root -g wheel -m 644 "$REPO/nas-copyparty/local.copyparty.plist"    /Library/LaunchDaemons/local.copyparty.plist
install -o root -g wheel -m 755 "$REPO/nas-jellyfin/jellyfin-server.sh"        /usr/local/sbin/jellyfin-server.sh
install -o root -g wheel -m 755 "$REPO/nas-copyparty/copyparty-server.sh"      /usr/local/sbin/copyparty-server.sh
install -o root -g wheel -m 644 "$REPO/nas-jellyfin/jellyfin.newsyslog.conf"   /etc/newsyslog.d/jellyfin.conf
install -o root -g wheel -m 644 "$REPO/nas-copyparty/copyparty.newsyslog.conf" /etc/newsyslog.d/copyparty.conf
echo "installed."

say "validating the newsyslog entries newsyslog will actually use"
newsyslog -nvv -f /etc/newsyslog.d/jellyfin.conf   | tail -4
newsyslog -nvv -f /etc/newsyslog.d/copyparty.conf  | tail -4

say "reloading both daemons (the plists changed, so bootout/bootstrap, not kickstart)"
#
# `launchctl bootout` returns before the job is actually gone: the label stays
# busy for as long as the old process takes to exit, which for Jellyfin means up
# to ExitTimeOut (60 s) spent optimising SQLite. Bootstrapping into a label that
# is not free yet fails with "Bootstrap failed: 5: Input/output error" — which is
# how the first run of this script left Jellyfin booted out and not running. So
# wait for the label to disappear, and never let one daemon's failure stop the
# other from being reloaded.
for svc in local.jellyfin local.copyparty; do
	if launchctl print "system/$svc" >/dev/null 2>&1; then
		launchctl bootout "system/$svc" 2>/dev/null || true
		n=0
		while launchctl print "system/$svc" >/dev/null 2>&1; do
			n=$((n + 1))
			if [ "$n" -ge 70 ]; then
				echo "  WARNING: $svc still loaded after ${n}s, trying anyway" >&2
				break
			fi
			sleep 1
		done
		echo "  booted out $svc after ${n}s"
	fi
	if launchctl bootstrap system "/Library/LaunchDaemons/$svc.plist"; then
		echo "  reloaded $svc"
	else
		echo "  FAILED to bootstrap $svc — it is now NOT running" >&2
	fi
done

say "waiting for startup, then verifying"
sleep 8
for svc in local.jellyfin local.copyparty; do
	printf '%s: ' "$svc"
	launchctl print "system/$svc" 2>/dev/null | grep -E '^\s+(state|pid) =' | tr -d '\t' | tr '\n' ' '
	echo
done
ls -l /var/log/jellyfin-server/ /var/log/copyparty-server/
