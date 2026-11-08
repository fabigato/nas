#!/bin/sh
#
# make-accounts.sh — write /usr/local/var/copyparty/accounts.conf from `pass`.
#
# The password lives in the password store as copyparty/fabian (that's what goes
# into Party UP! and the browser login). Only its argon2 hash, with a fresh
# random salt, ever reaches disk here. Re-run after `pass generate -f
# copyparty/fabian` to rotate it, then restart the daemon:
#   sudo launchctl kickstart -k system/local.copyparty
#
# Run as fabigato (it needs your GPG key), not with sudo.

set -eu

OUT=/usr/local/var/copyparty/accounts.conf
CPP=/opt/homebrew/bin/copyparty
ENTRY=copyparty/fabian

[ -d "$(dirname "$OUT")" ] || { echo "missing $(dirname "$OUT"); run the install steps first" >&2; exit 2; }

umask 077
salt=$(openssl rand -base64 18)
hash=$(pass show "$ENTRY" | head -n1 | "$CPP" --ah-alg argon2 --ah-salt "$salt" --ah-gen - 2>/dev/null | tail -n1)

case "$hash" in
	+?*) ;;
	*) echo "hashing failed (pass show $ENTRY or copyparty --ah-gen)" >&2; exit 1 ;;
esac

tmp="$OUT.tmp.$$"
printf '[global]\n  ah-alg: argon2\n  ah-salt: %s\n\n[accounts]\n  fabian: %s\n' "$salt" "$hash" >"$tmp"
mv "$tmp" "$OUT"
echo "wrote $OUT"
