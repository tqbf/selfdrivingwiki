#!/bin/bash
# Shared post-run assertion for the opt-in app test tier (WikiFSAppTests).
#
# Issue #1398: a `WIKIFS_APP_TESTS=1` invocation once exited 0 with ZERO
# WikiFSAppTests test lines — the opt-in target silently did not execute, yet
# the run was reported green. Whatever drops the bundle (stale manifest/plan
# layer, helper death) is invisible to `swift test`'s own exit code, so the
# gate cannot trust the exit code alone: it must find EVIDENCE of execution in
# the run log, and fail the invocation when the evidence is absent.
#
# Contract enforced here: when WIKIFS_APP_TESTS=1, the invocation either
# demonstrates that the opt-in target executed, or FAILS loudly. Never a
# silent green.
#
# Evidence definition: Swift Testing emits one line per executed test, of the
# shape
#   ... (WikiFSAppTests.OptInGateSentinelTests/optInFlagIsSet()) passed after 0.004 seconds.
# Suites and tests that merely START print "started." lines. Only the
# "passed after"/"failed after" lines prove execution, so those are the ones
# counted. A run whose log lacks a matching executed line for the expectation
# regex fails this gate even when `swift test` exited 0.
#
# Callers narrow the expectation with OPTIN_TEST_EXPECT (or the runner's
# --expect flag) when the invocation deliberately filters to a subset — e.g.
# `--filter ChatFooTests` — and must pass the suite they expect to see. The
# default expectation is the sentinel inside the app target, which makes
# "the target ran" and "the sentinel ran" the same observable fact. The two
# alternatives cover both output modes: plain `swift test` prints the suite's
# display name, and verbose output (`swift test -v`, the watchdog) prints the
# module-qualified ID.
#
# Related: #1422 (the runner can also die MID-RUN with exit 0 and no summary,
# dropping hundreds of already-scheduled tests). This gate counts execution
# evidence, so a mid-run death still shows executed lines and passes here;
# the missing-summary half of that failure mode needs its own guard and is
# deliberately out of scope for #1398.

# Counts executed (passed-or-failed) log lines matching the expectation.
# Args: <log-file> <expect-regex>. Prints the count.
optin_gate_count_executed() {
    local log_file="$1"
    local expect="$2"
    grep -E "${expect}.*( passed after | failed after )" "$log_file" | wc -l | tr -d ' '
}

# Counts started-but-not-necessarily-finished lines matching the expectation.
# Diagnostic only: surfaces the #1422-style started-without-finishing shape.
optin_gate_count_started() {
    local log_file="$1"
    local expect="$2"
    grep -E "${expect}.* started\." "$log_file" | wc -l | tr -d ' '
}

# The gate. Args: <log-file> <label>. Expectation comes from
# OPTIN_TEST_EXPECT (set it for filtered runs). Returns 1 and prints a loud,
# actionable failure when no executed line matches.
optin_gate_assert_executed() {
    local log_file="$1"
    local label="$2"
    local expect="${OPTIN_TEST_EXPECT:-WikiFSAppTests\\.OptInGateSentinelTests|\"Opt-in gate sentinel\"}"
    local executed started
    executed="$(optin_gate_count_executed "$log_file" "$expect")"
    started="$(optin_gate_count_started "$log_file" "$expect")"

    echo "==> opt-in gate: label=${label} expect=${expect}"
    echo "==> opt-in gate: executed=${executed} started=${started} log=${log_file}"

    if [ "$executed" -eq 0 ]; then
        echo ""
        echo "✗ OPT-IN APP TEST GATE FAILURE (#1398)"
        echo "  WIKIFS_APP_TESTS=1 was set, but the run log contains ZERO executed"
        echo "  tests matching: ${expect}"
        echo "  The opt-in WikiFSAppTests target did not demonstrably run."
        echo "  This invocation is a false green; do not trust it."
        echo ""
        echo "  If this run deliberately filtered to a subset, set OPTIN_TEST_EXPECT"
        echo "  (or pass --expect to scripts/test-optin-app-tests.sh) with the suite"
        echo "  you expected to execute."
        echo ""
        echo "  Last 20 log lines for triage:"
        tail -20 "$log_file" | sed 's/^/    /'
        return 1
    fi
    return 0
}
