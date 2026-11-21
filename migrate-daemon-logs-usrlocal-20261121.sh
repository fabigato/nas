#!/bin/sh
# One-off migration, 2026-11-21, second pass.
#
# Supersedes migrate-daemon-logs-20261121.sh, which moved the jellyfin and
# copyparty logs from /var/log itself into fabigato-owned directories *under*
# /var/log. That healed a deleted log FILE -- launchd recreates it on the next
# spawn -- but not a deleted log DIRECTORY, because /var/log is root:wheel 0755
# and nothing running as fabigato can create a directory in it either. The sweep
# that started all this took the macOS 27.2.1 update on 2026-11-20 with it, and
# there is no reason to expect the next update to behave differently.
#
# This pass does two things, for all three non-root daemons at once:
#
#   1. Moves every log out of /var/log into /usr/local/var/log, a tree fabigato
#      owns end to end and the macOS installer does not manage. Each wrapper
#      `mkdir -p`s its own directories on every start, so it can always put them
#      back by itself.
#
#   2. Removes StandardOutPath/StandardErrorPath from all three plists. launchd
#      then has no log file to open, so it can no longer fail to start a service
#      over one. Each wrapper redirects its own stdout/stderr into console.log
#      instead -- guarded, so a redirect that cannot be made costs the console
#      capture and not the service.
#
# All three move together because they share the one new parent directory and
# were all taken down by the same sweep. The LM Studio daemon's files live in
# the local_llm repo; see LLM_REPO below.
#
# Idempotent: safe to re-run.
set -eu

REPO=/Users/fabigato/repos/nas/scripts
LLM_REPO=/Users/fabigato/repos/local_llm/llmster/launchd
NEW=/usr/local/var/log

say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

say "creating the fabigato-owned log tree"
install -d -o fabigato -g staff -m 755 "$NEW"
install -d -o fabigato -g staff -m 755 \
	"$NEW/jellyfin-server" "$NEW/jellyfin" \
	"$NEW/copyparty-server" "$NEW/copyparty" \
	"$NEW/llmster"
ls -ld "$NEW" "$NEW"/*

# Stop everything first: Serilog and copyparty hold open descriptors on the
# files about to move, and a moved inode keeps receiving writes that nobody will
# look at again. bootout returns before the job is gone, so wait for the label.
say "stopping the three daemons"
for svc in local.jellyfin local.copyparty com.local.llmster; do
	launchctl print "system/$svc" >/dev/null 2>&1 || { echo "  $svc not loaded"; continue; }
	launchctl bootout "system/$svc" 2>/dev/null || true
	n=0
	while launchctl print "system/$svc" >/dev/null 2>&1; do
		n=$((n + 1))
		if [ "$n" -ge 70 ]; then
			echo "  WARNING: $svc still loaded after ${n}s, continuing anyway" >&2
			break
		fi
		sleep 1
	done
	echo "  booted out $svc after ${n}s"
done

# launchd.log becomes console.log: launchd no longer writes it, the wrapper does.
say "moving existing logs in, keeping their history"
move_one() {
	[ -e "$1" ] || return 0
	mv -v "$1" "$2"
}
for pair in "jellyfin-server:$NEW/jellyfin-server" "copyparty-server:$NEW/copyparty-server" "llmster-server:$NEW/llmster"; do
	old="/var/log/$(echo "$pair" | cut -d: -f1)"
	dst=$(echo "$pair" | cut -d: -f2)
	[ -d "$old" ] || continue
	move_one "$old/wrapper.log" "$dst/wrapper.log"
	move_one "$old/launchd.log" "$dst/console.log"
	for f in "$old"/*.bz2; do
		[ -e "$f" ] || continue
		mv -v "$f" "$dst/"
	done
	rmdir "$old" 2>/dev/null && echo "  removed empty $old" || true
done

# The servers' own logs: Serilog's log_*.log and copyparty's monthly files.
for svc in jellyfin copyparty; do
	[ -d "/var/log/$svc" ] || continue
	find "/var/log/$svc" -mindepth 1 -maxdepth 1 -exec mv -v {} "$NEW/$svc/" \; || true
	rmdir "/var/log/$svc" 2>/dev/null && echo "  removed empty /var/log/$svc" || true
done

chown -R fabigato:staff "$NEW"

say "installing plists, wrappers and configs"
install -o root -g wheel -m 644 "$REPO/nas-jellyfin/local.jellyfin.plist"       /Library/LaunchDaemons/local.jellyfin.plist
install -o root -g wheel -m 644 "$REPO/nas-copyparty/local.copyparty.plist"     /Library/LaunchDaemons/local.copyparty.plist
install -o root -g wheel -m 644 "$LLM_REPO/com.local.llmster.plist"             /Library/LaunchDaemons/com.local.llmster.plist
install -o root -g wheel -m 755 "$REPO/nas-jellyfin/jellyfin-server.sh"         /usr/local/sbin/jellyfin-server.sh
install -o root -g wheel -m 755 "$REPO/nas-copyparty/copyparty-server.sh"       /usr/local/sbin/copyparty-server.sh
install -o root -g wheel -m 755 "$LLM_REPO/llmster-server.sh"                   /usr/local/sbin/llmster-server.sh
install -o root -g wheel -m 644 "$REPO/nas-jellyfin/jellyfin.newsyslog.conf"    /etc/newsyslog.d/jellyfin.conf
install -o root -g wheel -m 644 "$REPO/nas-copyparty/copyparty.newsyslog.conf"  /etc/newsyslog.d/copyparty.conf
install -o root -g wheel -m 644 "$LLM_REPO/llmster.newsyslog.conf"              /etc/newsyslog.d/llmster.conf
# copyparty.conf carries the `lo` request-log path, which moved with the rest.
install -o fabigato -g staff -m 644 "$REPO/nas-copyparty/copyparty.conf"        /usr/local/var/copyparty/copyparty.conf
echo "installed."

say "the plists must now name no log path at all"
for f in local.jellyfin local.copyparty com.local.llmster; do
	if grep -Eq "<key>Standard(Out|Error)Path</key>" "/Library/LaunchDaemons/$f.plist"; then
		echo "  FAIL: $f.plist still sets a log path" >&2
		exit 1
	fi
	echo "  ok: $f.plist has none"
done

say "validating the newsyslog entries newsyslog will actually use"
newsyslog -nvv -f /etc/newsyslog.d/jellyfin.conf  | tail -4
newsyslog -nvv -f /etc/newsyslog.d/copyparty.conf | tail -4
newsyslog -nvv -f /etc/newsyslog.d/llmster.conf   | tail -4

say "starting them again"
for svc in local.jellyfin local.copyparty com.local.llmster; do
	if launchctl bootstrap system "/Library/LaunchDaemons/$svc.plist"; then
		echo "  started $svc"
	else
		echo "  FAILED to bootstrap $svc -- it is now NOT running" >&2
	fi
done

say "waiting for startup, then verifying"
sleep 10
for svc in local.jellyfin local.copyparty com.local.llmster; do
	printf '%s: ' "$svc"
	launchctl print "system/$svc" 2>/dev/null | grep -E '^[[:space:]]+(state|pid|runs) =' | tr -d '\t' | tr '\n' ' '
	echo
done
ls -l "$NEW"/*/
