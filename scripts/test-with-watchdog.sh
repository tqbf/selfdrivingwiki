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
#      TEST_TIMEOUT), logged to a timestamped file under tmp/test-logs/.
#   2. On timeout, signals ONLY the `swift test` child it launched, and only
#      while bash still lists that PID as a running job of this shell. It never
#      sweeps helpers by command line, path, process group, session, or user.
#   3. On any exit, prints the slowest tests (parsed from Swift Testing's own
#      "passed/failed after N seconds" lines) so a newly-slow test is visible
#      as a trend, not just a future hang.
#
# Signal safety (#1051): this script previously ran
# `pkill -f "[s]wiftpm-testing-helper.*$REPO_ROOT/.build"` on every exit and
# used `kill -0` for liveness. Both select by appearance rather than ownership.
# The sweep is gone, and every signal now goes through the verified-child
# boundary in scripts/lib/test-watchdog-process-control.sh.
#
# Orphaned helpers are NOT reaped here. A helper belongs to the `swift test`
# process that launched it; if one is left behind, reap it by hand.
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

echo "==> swift test -v --parallel --num-workers ${NUM_WORKERS} $* "
echo "==> log: $LOG_FILE"
echo "==> timeout: ${TIMEOUT_SECS}s (override with TEST_TIMEOUT=<seconds>)"

swift test -v --parallel --num-workers "$NUM_WORKERS" "$@" >"$LOG_FILE" 2>&1 &
TEST_PID=$!
# The only background job this script starts, so it is always %1. Signals are
# addressed by this jobspec; the PID is used only for the liveness loop and for
# `wait`, neither of which sends a signal.
TEST_JOB="%1"

START_TS=$(date +%s)
TIMED_OUT=0
# `watchdog_running_child_pids` must be evaluated in this shell, which owns the
# job. The loop ends when the child leaves the running-job table, either by
# finishing or by being signalled.
while watchdog_is_verified_child "$TEST_PID" "$(watchdog_running_child_pids)"; do
    ELAPSED=$(($(date +%s) - START_TS))
    if [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
        TIMED_OUT=1
        break
    fi
    sleep 2
done

if [ "$TIMED_OUT" -eq 1 ]; then
    echo ""
    echo "✗ TIMED OUT after ${TIMEOUT_SECS}s — signaling only the verified swift test child."
    # Addressed by jobspec, never by PID: bash resolves ownership and signals in
    # one step, so there is no interval in which the number could be recycled.
    # This script launches exactly one background job, so %1 is that job.
    watchdog_signal_job TERM "$TEST_JOB" || true
    sleep 1
    # Escalate only if the job is still running. A child that exited on TERM is
    # the expected outcome, not a failure worth reporting.
    if watchdog_is_verified_child "$TEST_PID" "$(watchdog_running_child_pids)"; then
        echo "==> child survived TERM; escalating to KILL."
        watchdog_signal_job KILL "$TEST_JOB" || true
    else
        echo "==> child exited on TERM; no KILL needed."
    fi
    EXIT_CODE=124
fi

# `wait` is safe and bounded here: the child has either finished on its own or
# been signalled above, so it is a terminated-but-unreaped job in both paths.
wait "$TEST_PID"
WAIT_STATUS=$?
if [ "$TIMED_OUT" -ne 1 ]; then
    EXIT_CODE=$WAIT_STATUS
fi

perl -ne '
    if (/Test (.+\(.*\)) started\./) { $started{$1} = 1 }
    if (/Test (.+\(.*\))(?: with \d+ test cases)? (passed|failed) after ([0-9.]+) seconds/) {
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
