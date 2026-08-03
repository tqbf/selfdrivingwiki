#!/bin/bash
# Unit tests for the watchdog process-control boundary (#1051).
#
# These tests never signal a real process except a `sleep` this script launched
# itself. The verification predicates are pure — they take a job-table snapshot
# as an argument — so refusal cases need no processes at all.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-watchdog-process-control.sh"

FAILURES=0
ASSERTIONS=0

pass() {
    ASSERTIONS=$((ASSERTIONS + 1))
    echo "  ✓ $1"
}

fail() {
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    echo "  ✗ $1"
}

expect_verified() {
    if watchdog_is_verified_child "$2" "$3"; then pass "$1"; else fail "$1"; fi
}

expect_refused() {
    if watchdog_is_verified_child "$2" "$3"; then fail "$1"; else pass "$1"; fi
}

echo "watchdog_is_verified_child — refusals (pure, no processes):"
SNAP=$'4242\n4243'
expect_verified "accepts a PID present in the snapshot" 4242 "$SNAP"
expect_verified "accepts the second PID in the snapshot" 4243 "$SNAP"
expect_refused "refuses a PID absent from the snapshot" 9999 "$SNAP"
expect_refused "refuses a prefix of a listed PID (4 vs 4242)" 4 "$SNAP"
expect_refused "refuses a numeric extension of a listed PID (42420)" 42420 "$SNAP"
expect_refused "refuses an empty snapshot" 4242 ""
expect_refused "refuses PID 0" 0 $'0'
expect_refused "refuses PID 1 (init)" 1 $'1'
expect_refused "refuses a negative PID (process group)" -4242 "$SNAP"
expect_refused "refuses a non-numeric PID" "abc" "$SNAP"
expect_refused "refuses an empty PID" "" "$SNAP"
expect_refused "refuses a PID with whitespace padding" " 4242" "$SNAP"
expect_refused "refuses this shell" "$$" "$(printf '%s\n' "$$")"
expect_refused "refuses this shell's parent" "$PPID" "$(printf '%s\n' "$PPID")"

echo "watchdog_signal_job — signal-name allowlist:"
for bad_signal in HUP STOP CONT USR1 9 -9; do
    if watchdog_signal_job "$bad_signal" "%1" 2>/dev/null; then
        fail "refuses $bad_signal"
    else
        pass "refuses $bad_signal"
    fi
done

echo "watchdog_signal_job — refuses anything that is not a jobspec:"
# A numeric PID must never reach kill, or the check-then-signal race returns.
for bad_target in 4242 -4242 "" "abc" "%" "%%1" "% 1" "1%"; do
    if watchdog_signal_job TERM "$bad_target" 2>/dev/null; then
        fail "refuses target '$bad_target'"
    else
        pass "refuses target '$bad_target'"
    fi
done

echo "live job — end to end via jobspec:"
sleep 30 &
LIVE_PID=$!
expect_verified "verifies a live direct child" "$LIVE_PID" "$(watchdog_running_child_pids)"

if watchdog_signal_job TERM "%1"; then
    pass "delivers TERM to a live job by jobspec"
else
    fail "delivers TERM to a live job by jobspec"
fi
wait %1 2>/dev/null

echo "the race the reviewer found — target exits AND is reaped after verification:"
sleep 0.1 &
RACE_PID=$!
RACE_SNAP="$(watchdog_running_child_pids)"
# Verification succeeded against this snapshot...
expect_verified "snapshot verified the child while it was running" "$RACE_PID" "$RACE_SNAP"
# ...then the child exits and bash reaps it, freeing the PID for reuse.
wait %1 2>/dev/null
# A numeric signal authorised by the now-stale snapshot would land on whatever
# holds that PID next. The jobspec boundary refuses instead.
if watchdog_signal_job TERM "%1" 2>/dev/null; then
    fail "refuses to signal a job reaped after verification"
else
    pass "refuses to signal a job reaped after verification"
fi

echo "reaped child — the PID-reuse window kill -0 would miss:"
sleep 0.1 &
GONE_PID=$!
sleep 1
GONE_SNAP="$(watchdog_running_child_pids)"
expect_refused "refuses a child that already exited" "$GONE_PID" "$GONE_SNAP"
wait "$GONE_PID" 2>/dev/null

echo "no broad matchers anywhere in the watchdog:"
for candidate in "$REPO_ROOT/scripts/test-with-watchdog.sh" \
    "$REPO_ROOT/scripts/lib/test-watchdog-process-control.sh"; do
    name="$(basename "$candidate")"
    # Skip comment lines: these files describe the removed sweep on purpose.
    body="$(grep -vE '^[[:space:]]*#' "$candidate")"
    for tool in pkill killall; do
        if printf '%s' "$body" | grep -q "$tool"; then
            fail "$name contains no $tool"
        else
            pass "$name contains no $tool"
        fi
    done
    if printf '%s' "$body" | grep -q 'kill -0'; then
        fail "$name contains no 'kill -0' liveness probe"
    else
        pass "$name contains no 'kill -0' liveness probe"
    fi
done

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "✓ all $ASSERTIONS assertions passed"
    exit 0
fi
echo "✗ $FAILURES of $ASSERTIONS assertions failed"
exit 1
