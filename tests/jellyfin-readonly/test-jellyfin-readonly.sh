#!/bin/sh
#
# test-jellyfin-readonly.sh — prove Jellyfin never writes to the media datasets.
#
# "Both libraries are read-only" was decided on 2026-08-23. Jellyfin has no
# read-only switch, so that decision lives in a scatter of settings — where
# metadata is stored, whether NFO savers are enabled, whether artwork is written
# next to the media, whether subtitle extraction lands beside the file. Any one
# of them silently flipped by a plugin, a library-creation dialog or a version
# upgrade puts writes on `tank/my_media`.
#
# Rather than trust that list, this asserts the property directly. ZFS can
# answer "did anything at all change in this dataset" exactly and cheaply:
# `written@<snapshot>` is bytes written since that snapshot, and `zfs diff`
# names the paths. That is a stronger statement than any audit of the settings
# page, and it stays true against settings that do not exist yet.
#
# Why it matters here specifically: writes into a snapshotted dataset are not
# just untidy. Every scan that touches the library pins its old blocks into the
# next nightly snapshot, so a chatty metadata writer inflates `usedbysnapshots`
# forever on the one dataset with 8-weekly-plus-6-monthly retention.
#
# ---------------------------------------------------------------------------
# Usage — three phases, because the scan in the middle is the slow part:
#
#   sudo sh test-jellyfin-readonly.sh baseline   # snapshot both datasets
#   sudo sh test-jellyfin-readonly.sh scan       # trigger a full library scan
#   sudo sh test-jellyfin-readonly.sh verify     # assert nothing was written
#   sudo sh test-jellyfin-readonly.sh clean      # drop the test snapshots
#
# `scan` needs JELLYFIN_API_KEY (Dashboard → API Keys). Without it, trigger the
# scan by hand from Dashboard → Scheduled Tasks → Scan All Libraries and skip
# straight to `verify`; the assertion does not care how the scan was started.
#
# Snapshots are named `test-jfro-*`, never `auto-*`. The production pruner in
# tank-snapshot.sh anchors on the `auto-` prefix, so it is structurally
# incapable of destroying these, and this script is structurally incapable of
# destroying a retention snapshot. Same discipline as tests/snapshot-retention/.
#
# Exit codes: 0 clean, 1 usage/precondition failure, 2 WRITES DETECTED.

set -u

ZFS=/usr/local/zfs/bin/zfs
ZPOOL=/usr/local/zfs/bin/zpool

DATASETS="tank/media tank/my_media"
PREFIX=test-jfro
STATE=/tmp/jellyfin-readonly.snap
JF=http://127.0.0.1:8096
JF_LOGS=/var/log/jellyfin

# The marker the scan guard counts. Jellyfin logs this once per completed run of
# the "Scan Media Library" scheduled task, whether it was triggered by the API,
# by the dashboard, or on its own schedule — so the guard does not care how the
# scan was started, only that one finished.
SCAN_MARKER='"Scan Media Library" Completed'

scan_count() {
	cat "$JF_LOGS"/log_*.log 2>/dev/null | grep -c "$SCAN_MARKER"
}

# macOS writes to any volume it can see, and none of it is Jellyfin's doing.
# These are reported but do not fail the test — see README for why Spotlight in
# particular is worth watching separately.
is_macos_noise() {
	case "$1" in
		*/.DS_Store|*/.Spotlight-V100/*|*/.fseventsd/*|\
		*/.TemporaryItems/*|*/.Trashes/*|*/.VolumeIcon.icns) return 0 ;;
		*) return 1 ;;
	esac
}

require_root() {
	[ "$(id -u)" -eq 0 ] || { echo "must run as root ($ZFS needs it)" >&2; exit 1; }
}

require_pool() {
	health=$("$ZPOOL" list -H -o health tank 2>/dev/null)
	case "$health" in
		ONLINE|DEGRADED) ;;
		"") echo "pool 'tank' is not imported" >&2; exit 1 ;;
		*)  echo "pool 'tank' is $health — refusing" >&2; exit 1 ;;
	esac
}

cmd_baseline() {
	require_root; require_pool
	stamp=$(date '+%Y-%m-%d-%H%M%S')
	snap="$PREFIX-$stamp"

	for ds in $DATASETS; do
		"$ZFS" snapshot "$ds@$snap" || { echo "snapshot failed: $ds@$snap" >&2; exit 1; }
		echo "created $ds@$snap"
	done

	# Two lines: the snapshot name, and how many library scans had completed at
	# baseline time. The second is what stops `verify` from passing when no scan
	# ever ran — see cmd_verify.
	{ echo "$snap"; scan_count; } >"$STATE"

	echo
	echo "Baseline taken ($(scan_count) library scans completed so far)."
	echo "Now run a full library scan, then:"
	echo "  sudo sh $0 verify"
}

cmd_scan() {
	[ -f "$STATE" ] || { echo "no baseline — run 'baseline' first" >&2; exit 1; }

	# Note this subcommand does NOT need root — it is one HTTP request. It is
	# listed with sudo in the usage only so the three phases read alike, and
	# that is a trap worth spelling out: `sudo` scrubs the environment, so
	# `sudo sh ... scan` cannot see JELLYFIN_API_KEY at all. Use `sudo -E`, or
	# drop the sudo entirely.
	if [ -z "${JELLYFIN_API_KEY:-}" ]; then
		echo "JELLYFIN_API_KEY is not set." >&2
		echo >&2
		echo "  Create one at: Dashboard -> API Keys" >&2
		echo "  Then:   JELLYFIN_API_KEY=xxx sh $0 scan" >&2
		echo >&2
		echo "  If you ran this with plain sudo, that is why the variable is" >&2
		echo "  missing — sudo scrubs the environment. This step needs no root." >&2
		echo >&2
		echo "  Or skip it: trigger the scan from Dashboard -> Scheduled Tasks." >&2
		exit 1
	fi

	code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
		-H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" \
		-H 'Content-Length: 0' \
		"$JF/Library/Refresh")

	# 204 is the documented success. Anything else is checked rather than
	# assumed, because a curl that reaches a server and is rejected still
	# exits 0 — the same silent-success trap that hid the Discord webhook
	# failure for weeks.
	[ "$code" = "204" ] || { echo "scan request returned HTTP $code (expected 204)" >&2; exit 1; }

	echo "scan triggered. It runs asynchronously — watch"
	echo "  tail -f /var/log/jellyfin/log_*.log"
	echo "and wait for the library scan to complete before running 'verify'."
}

cmd_verify() {
	require_root; require_pool
	[ -f "$STATE" ] || { echo "no baseline — run 'baseline' first" >&2; exit 1; }
	snap=$(sed -n 1p "$STATE")
	base_scans=$(sed -n 2p "$STATE")

	# --- the guard against a vacuous pass ---------------------------------
	# Without this, a run where the scan step silently failed reports
	# "written: 0B — PASS", which is a green result on a test that exercised
	# nothing. That is the single most dangerous shape a test can have, and it
	# happened on the first real run of this suite: `scan` aborted for a missing
	# API key and `verify` cheerfully passed.
	#
	# Counting completed scans rather than parsing timestamps is deliberate. It
	# needs no date arithmetic in /bin/sh, and it is agnostic about how the scan
	# was triggered — API, dashboard button, or the nightly schedule all count.
	now_scans=$(scan_count)
	if [ -z "$base_scans" ]; then
		echo "FAIL — baseline predates the scan guard. Re-run 'baseline'." >&2
		exit 1
	fi
	if [ "$now_scans" -lt "$base_scans" ]; then
		# Jellyfin rotates its logs daily, so the count can legitimately drop.
		# Fail closed: an unknown answer is not a pass.
		echo "FAIL — scan count went backwards ($base_scans -> $now_scans)." >&2
		echo "       The log rotated under the test. Re-run 'baseline'." >&2
		exit 1
	fi
	if [ "$now_scans" -eq "$base_scans" ]; then
		echo "FAIL — no library scan completed since the baseline." >&2
		echo >&2
		echo "       Nothing was exercised, so 'written: 0B' would prove nothing." >&2
		echo "       Trigger a scan first:" >&2
		echo "         Dashboard -> Scheduled Tasks -> Scan Media Library" >&2
		echo "       or set JELLYFIN_API_KEY and run: sudo -E sh $0 scan" >&2
		echo "       Then wait for it to finish and re-run 'verify'." >&2
		exit 1
	fi

	echo "Scans completed since baseline: $((now_scans - base_scans))"
	echo

	violations=0
	noise=0

	for ds in $DATASETS; do
		out="/tmp/jfro-$$-$(echo "$ds" | tr / _).out"
		written=$("$ZFS" get -H -o value "written@$snap" "$ds" 2>/dev/null)
		if [ -z "$written" ]; then
			echo "FAIL  $ds — no snapshot $ds@$snap (baseline lost?)" >&2
			exit 1
		fi

		echo "--- $ds  (written since $snap: $written)"

		# `written` is the coarse signal and it counts macOS noise too, so it
		# cannot be the assertion on its own. zfs diff names the paths, and -F
		# adds a type column so a modified directory can be told from a
		# modified file — a touched directory mtime is a consequence of noise
		# inside it, not a write to the library.
		"$ZFS" diff -F "$ds@$snap" "$ds" 2>/dev/null | while IFS=$(printf '\t') read -r change type path rest; do
			[ -n "${path:-}" ] || continue
			if is_macos_noise "$path"; then
				echo "  noise  $change $type $path"
			elif [ "$change" = "M" ] && [ "$type" = "/" ]; then
				echo "  dir    $change $type $path"
			else
				echo "  WRITE  $change $type $path"
			fi
		done >"$out"

		cat "$out"
		# grep -c always prints a count and exits 1 when that count is zero, so
		# it is used bare — a `|| echo 0` fallback would print a second zero and
		# turn the arithmetic below into a syntax error on the passing path.
		v=$(grep -c '^  WRITE ' "$out")
		n=$(grep -c '^  noise ' "$out")
		violations=$((violations + v))
		noise=$((noise + n))
		rm -f "$out"
	done

	echo
	if [ "$violations" -eq 0 ]; then
		echo "PASS — no writes to the media datasets attributable to Jellyfin."
		[ "$noise" -gt 0 ] && echo "      ($noise macOS metadata entries ignored; see README)"
		echo
		echo "Drop the test snapshots with:  sudo sh $0 clean"
		exit 0
	fi

	echo "FAIL — $violations write(s) into a read-only media dataset."
	echo
	echo "Most likely causes, in the order worth checking:"
	echo "  * Library settings → 'Save artwork into media folders'"
	echo "  * Library settings → 'Save subtitles into media folders'"
	echo "  * Metadata savers (Nfo) enabled for the library"
	echo "  * A plugin with its own writer"
	echo "Leave the snapshots in place while investigating — they are the evidence."
	exit 2
}

cmd_clean() {
	require_root
	[ -f "$STATE" ] || { echo "nothing to clean"; exit 0; }
	snap=$(sed -n 1p "$STATE")

	# Guard the name shape before destroying anything. A truncated or empty
	# state file must never turn into `zfs destroy tank/media@`.
	case "$snap" in
		"$PREFIX"-*) ;;
		*) echo "refusing to destroy '$snap' — not a $PREFIX- snapshot" >&2; exit 1 ;;
	esac

	for ds in $DATASETS; do
		if "$ZFS" list -H -t snapshot "$ds@$snap" >/dev/null 2>&1; then
			"$ZFS" destroy "$ds@$snap" && echo "destroyed $ds@$snap"
		fi
	done
	rm -f "$STATE"
}

case "${1:-}" in
	baseline) cmd_baseline ;;
	scan)     cmd_scan ;;
	verify)   cmd_verify ;;
	clean)    cmd_clean ;;
	*) echo "usage: $0 {baseline|scan|verify|clean}" >&2; exit 1 ;;
esac
