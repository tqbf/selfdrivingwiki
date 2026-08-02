#!/bin/bash
# Non-signaling unit coverage for scripts/lib/test-watchdog-process-control.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-watchdog-process-control.sh"

OBSERVATION=""
SIGNAL_CALLS=0

fail() {
    echo "test-with-watchdog process-control test failed: $1" >&2
    exit 1
}

expected_identity() {
    printf '42\t%s\tbirth:20260802T065103.123456\n' "$$"
}

# The production sender must reject direct sourceable calls when the default
# observer cannot independently establish a process identity. This path never
# reaches the raw builtin sender.
if watchdog_send_signal TERM 42 "$(expected_identity)"; then
    fail "production sender accepted an identity-unavailable direct call"
fi

watchdog_observe_process() {
    [[ -n "$OBSERVATION" ]] || return 1
    printf '%s\n' "$OBSERVATION"
}

watchdog_send_signal() {
    SIGNAL_CALLS=$((SIGNAL_CALLS + 1))
    return 0
}

assert_refuses() {
    local label="$1"
    local pid="$2"
    local identity="$3"
    local current_observation="$4"

    OBSERVATION="$current_observation"
    SIGNAL_CALLS=0
    if watchdog_signal_verified_child TERM "$pid" "$identity"; then
        fail "$label unexpectedly accepted a signal target"
    fi
    [[ "$SIGNAL_CALLS" -eq 0 ]] || fail "$label invoked the signal seam"
}

assert_capture_refuses() {
    local label="$1"
    local pid="$2"
    local observation="$3"

    OBSERVATION="$observation"
    if watchdog_capture_identity "$pid" >/dev/null; then
        fail "$label unexpectedly produced an identity"
    fi
}

identity="$(expected_identity)"

assert_capture_refuses malformed-observation 42 'not-a-process-record'
assert_capture_refuses zero-observation 42 "0 $$ birth:20260802T065103.123456"
assert_capture_refuses reused-pid-observation 42 "43 $$ birth:20260802T065103.123456"
assert_refuses malformed-pid 'not-a-pid' "$identity" "42 $$ birth:20260802T065103.123456"
assert_refuses zero-sentinel 0 "$identity" "42 $$ birth:20260802T065103.123456"
assert_refuses one-sentinel 1 "$identity" "42 $$ birth:20260802T065103.123456"
assert_refuses negative-sentinel -42 "$identity" "42 $$ birth:20260802T065103.123456"
assert_refuses stale-or-reused 42 "$identity" "42 $$ birth:20260802T065104.123456"
assert_refuses non-child 42 "$identity" "42 999 birth:20260802T065103.123456"
assert_refuses unavailable-identity 42 "$identity" ""

OBSERVATION="42 $$ birth:20260802T065103.123456"
SIGNAL_CALLS=0
watchdog_signal_verified_child TERM 42 "$identity" || fail "matching child identity was refused"
[[ "$SIGNAL_CALLS" -eq 1 ]] || fail "matching child identity did not invoke fake seam"
