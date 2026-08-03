#!/bin/bash
# Wraps `swift test -v` with a hard wall-clock timeout and a post-run summary,
# so a hung test is visible in minutes instead of blocking indefinitely.
#
# Why this exists: `swift test`'s own `.timeLimit` trait (Swift Testing) only
# works by cancelling the test's Task — it cannot interrupt a suspended
# `withCheckedContinuation` whose completion handler never fires (e.g. a
# WKWebView `evaluateJavaScript` reply starved off the cooperative thread pool
# by another concurrently-running blocking suite; see #664/#732). That leaves
# the WHOLE `swift test` process hanging with no diagnostic. This script:
#   1. Runs the suite with a real timeout (default 900s; override with
#      TEST_TIMEOUT), tee'd to a timestamped log under tmp/test-logs/.
#   2. On timeout, signals only the `swift test` child that this script
#      launched and has just re-verified as its direct child. It never sweeps
#      helpers by path, process group, session, or user.
#   3. On any exit, prints the slowest tests (parsed from Swift Testing's own
#      "passed/failed after N seconds" lines) so a newly-slow test is visible
#      as a trend, not just a future hang.
#
# Usage: scripts/test-with-watchdog.sh [swift test args...]
#   TEST_TIMEOUT=1200 scripts/test-with-watchdog.sh --filter QueueEngineTests

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
source "$REPO_ROOT/scripts/lib/test-watchdog-process-control.sh"

TIMEOUT_SECS="${TEST_TIMEOUT:-900}"
NUM_WORKERS="${SWIFT_TEST_NUM_WORKERS:-1}"
LOG_DIR="tmp/test-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/swift-test-$(date +%Y%m%d-%H%M%S).log"

if ! watchdog_has_precise_identity_observer; then
    echo "test watchdog: high-precision process identity unavailable; refusing to launch an unbounded test child" >&2
    exit 78
fi

echo "==> swift test -v --parallel --num-workers ${NUM_WORKERS} $* "
echo "==> log: $LOG_FILE"
echo "==> timeout: ${TIMEOUT_SECS}s (override with TEST_TIMEOUT=<seconds>)"

swift test -v --parallel --num-workers "$NUM_WORKERS" "$@" >"$LOG_FILE" 2>&1 &
TEST_PID=$!
TEST_IDENTITY="$(watchdog_capture_identity "$TEST_PID")"

if [[ -z "$TEST_IDENTITY" ]] || ! watchdog_identity_is_direct_child "$TEST_IDENTITY"; then
    echo "test watchdog: post-launch process identity unavailable; refusing signal and wait for test child PID $TEST_PID" >&2
    exit 78
fi

START_TS=$(date +%s)
TIMED_OUT=0
while watchdog_is_verified_direct_child "$TEST_PID" "$TEST_IDENTITY"; do
    ELAPSED=$(( $(date +%s) - START_TS ))
    if [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
        TIMED_OUT=1
        break
    fi
    sleep 2
done

if [ "$TIMED_OUT" -ne 1 ]; then
    # An unproven running job might use a reused PID. Do not wait for it.
    # Bash lists only running jobs with `jobs -pr`.
    # If it is absent, `wait` reaps an already-completed child.
    if jobs -pr | grep -Fx -- "$TEST_PID" >/dev/null; then
        echo "test watchdog: child identity is no longer verified; refusing signal and wait" >&2
        exit 78
    fi
    # The child already completed, so this wait is bounded.
    wait "$TEST_PID"
    EXIT_CODE=$?
else
    echo ""
    echo "✗ TIMED OUT after ${TIMEOUT_SECS}s — signaling only the verified swift test child."
    if ! watchdog_signal_verified_child TERM "$TEST_PID" "$TEST_IDENTITY"; then
        echo "test watchdog: refused TERM for unverified test child" >&2
    fi
    sleep 1
    if ! watchdog_signal_verified_child KILL "$TEST_PID" "$TEST_IDENTITY"; then
        echo "test watchdog: refused KILL for unverified test child" >&2
    fi
    EXIT_CODE=124
fi

perl -ne '
    if (/Test (.+\(.*\)) started\./) { $started{$1} = 1 }
    if (/Test (.+\(.*\)) (passed|failed) after ([0-9.]+) seconds/) {
        $finished{$1} = 1;
        push @durations, [$3 + 0, $2, $1];
    }
    END {
        print "\n==> Slowest tests (top 15):\n";
        my $shown = 0;
        for (sort { $b->[0] <=> $a->[0] } @durations) {
            last if $shown++ >= 15;
            printf "  %8.3fs  %-7s %s\n", $_->[0], $_->[1], $_->[2];
        }
        print "\n==> STARTED BUT NEVER FINISHED (the hang, if any):\n";
        my $any = 0;
        for my $name (sort keys %started) {
            unless ($finished{$name}) { print "  - $name\n"; $any = 1; }
        }
        print "  (none)\n" unless $any;
    }
' "$LOG_FILE"

echo ""
echo "==> Full log: $LOG_FILE"

if [ "$TIMED_OUT" -eq 1 ]; then
    echo "==> Exiting 124 (timeout)."
fi
exit "$EXIT_CODE"
