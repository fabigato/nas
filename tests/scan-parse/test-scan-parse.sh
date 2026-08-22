#!/bin/sh
#
# test-scan-parse.sh — fixture tests for tank-scrub.sh's scan_summary() parser
# and the verdict patterns that consume its output.
#
# WHY THIS EXISTS
# The pool holds ~10 MB, so a real scrub of it finishes in about 2 seconds. That
# is far too fast for the watch loop to ever observe an in-progress scan, which
# means the progress-logging branch, the stall check and every "is it still
# running" decision are unreachable by live testing until the pool has real data
# in it. The 2026-08-22 kickstart test passed with exit 0 and proved exactly
# nothing about them — and a first-line-only parser bug was sitting in that path
# at the time, logging a static string where the progress numbers should be.
#
# So the branches get tested against captured `zpool status` output instead.
# This is a parser test, not a substitute for a real long scrub: it proves the
# script reads a running scrub correctly, not that the loop behaves over 20
# hours. Re-run a real scrub with progress lines once there is enough data for
# one to take more than a couple of minutes.
#
# The awk program under test is EXTRACTED FROM tank-scrub.sh at run time rather
# than copied here, so there is no second version to drift out of sync. If the
# extraction fails the test fails loudly instead of silently testing nothing.
#
# Usage:  sh tests/scan-parse/test-scan-parse.sh [path-to-tank-scrub.sh]
# Default target is the repo copy, not the installed one. To test what is
# actually deployed:
#   sh tests/scan-parse/test-scan-parse.sh /usr/local/sbin/tank-scrub.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-$HERE/../../scripts/nas-scrub/tank-scrub.sh}
FIXTURES=$HERE/fixtures

if [ ! -r "$SCRIPT" ]; then
	echo "FATAL: cannot read $SCRIPT" >&2
	exit 1
fi

# Pull the awk body out of scan_summary(). Bounded by the `awk '` that opens it
# and the lone `'` that closes it, so it survives edits to the comments and the
# surrounding function.
AWKPROG=$(awk '
	/^scan_summary\(\) \{/        { in_fn = 1; next }
	in_fn && /awk .$/             { in_awk = 1; next }
	in_awk && /^[ \t]*.$/         { exit }
	in_awk                        { print }
' "$SCRIPT")

if [ -z "$AWKPROG" ]; then
	echo "FATAL: could not extract the scan_summary() awk program from $SCRIPT." >&2
	echo "       The function was probably restructured. Fix this extractor" >&2
	echo "       rather than pasting a copy of the parser in here." >&2
	exit 1
fi

pass=0
fail=0

# $1 = fixture basename, $2 = expected scan_summary output
check_parse() {
	got=$(awk "$AWKPROG" "$FIXTURES/$1")
	if [ "$got" = "$2" ]; then
		pass=$((pass + 1))
		echo "ok   parse $1"
	else
		fail=$((fail + 1))
		echo "FAIL parse $1"
		echo "       expected: [$2]"
		echo "       got:      [$got]"
	fi
}

# $1 = label, $2 = the scan string, $3 = expected verdict.
#
# Mirrors the case patterns in tank-scrub.sh. This is the one place a copy is
# unavoidable, since those cases are inline control flow rather than a function
# — so if the script's patterns change, change these too. The whole point is
# catching a pattern that matches the wrong state, e.g. an in-progress block
# containing the substring "0B repaired" being read as "repaired 0B".
check_verdict() {
	verdict=unknown
	case "$2" in
	*"in progress"*) verdict=running ;;
	*"canceled"*) verdict=canceled ;;
	*"with 0 errors"*)
		case "$2" in
		*"repaired 0B"*) verdict=clean ;;
		*) verdict=repaired ;;
		esac
		;;
	*"none requested"*) verdict=never ;;
	*) verdict=errors ;;
	esac

	if [ "$verdict" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok   verdict $1 -> $verdict"
	else
		fail=$((fail + 1))
		echo "FAIL verdict $1: expected $3, got $verdict"
	fi
}

echo "== scan_summary() against $SCRIPT"

# A finished scrub is a single line and must come back unchanged.
check_parse completed-clean.txt \
	"scrub repaired 0B in 00:00:02 with 0 errors on Sat Aug 22 23:41:18 2026"

# THE REGRESSION THIS FILE WAS WRITTEN FOR. A running scrub spans three lines
# and the numbers are all on lines 2 and 3. A parser that stops at line 1 still
# produces a plausible-looking string, which is why the bug survived review.
check_parse in-progress.txt \
	"scrub in progress since Sat Aug 22 23:41:16 2026 | 1.20T / 7.10T scanned at 500M/s, 800G / 7.10T issued at 300M/s | 0B repaired, 11.27% done, 05:12:33 to go"

check_parse completed-with-errors.txt \
	"scrub repaired 128K in 04:12:07 with 3 errors on Sat Aug 22 04:12:09 2026"

check_parse canceled.txt \
	"scrub canceled on Sat Aug 22 23:50:01 2026"

# A resilver must read as "in progress" too — the preflight skip and the watch
# loop both key off that substring, and scrubbing on top of a resilver is the
# thing we are avoiding.
check_parse resilver.txt \
	"resilver in progress since Sat Aug 22 23:45:00 2026 | 400G / 7.10T scanned at 200M/s, 380G / 7.10T issued at 190M/s | 0B resilvered, 5.35% done, 09:48:12 to go"

# Fresh pool, or one where the counters were cleared. Must not be read as an
# error state — `before` is only logged, never used as a verdict.
check_parse none-requested.txt "none requested"

# Terminator check: nothing from the config block may leak into the summary.
check_parse trailing-sections.txt \
	"scrub in progress since Sat Aug 22 23:41:16 2026 | 0B repaired, 11.27% done, 05:12:33 to go"

echo "== verdict patterns"
check_verdict completed-clean \
	"scrub repaired 0B in 00:00:02 with 0 errors on Sat Aug 22 23:41:18 2026" clean
check_verdict completed-repaired \
	"scrub repaired 128K in 04:12:07 with 0 errors on Sat Aug 22 04:12:09 2026" repaired
check_verdict completed-errors \
	"scrub repaired 128K in 04:12:07 with 3 errors on Sat Aug 22 04:12:09 2026" errors
check_verdict canceled "scrub canceled on Sat Aug 22 23:50:01 2026" canceled
check_verdict never "none requested" never

# The word-order trap. An in-progress block says "0B repaired"; a completed
# clean one says "repaired 0B". Reversed, this reads as a finished clean scrub
# and the daemon would stop watching an hour into a 20-hour scan.
check_verdict in-progress-contains-0B-repaired \
	"scrub in progress since Sat Aug 22 23:41:16 2026 | 0B repaired, 11.27% done, 05:12:33 to go" running

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ] || exit 1
