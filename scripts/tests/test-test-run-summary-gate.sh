#!/bin/bash
# Unit tests for the #1422 run-summary reconciliation gate.
#
# The gate is a pure function of a log file, so these tests exercise it with
# synthetic logs in a temp directory. No swift test process is involved: the
# forced-deficit shape is exactly the log a mid-run runner death leaves
# behind (a "Test run started" header with no matching summary), which is
# the point — the gate must catch it without needing the death to happen.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/test-run-summary-gate.sh"

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

expect_gate_ok() {
    if test_run_summary_gate_assert "$2" "unit-test" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

expect_gate_fails() {
    if test_run_summary_gate_assert "$2" "unit-test" >/dev/null 2>&1; then fail "$1"; else pass "$1"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A green parallel run: three bundles started, three summaries.
printf '%s\n' \
    "◇ Test run started." \
    "◇ Test run with 2855 tests passed after 845.2 seconds." \
    "◇ Test run started." \
    "◇ Test run with 120 tests passed after 12.0 seconds." \
    "◇ Test run started." \
    "◇ Test run with 40 tests failed after 3.0 seconds." \
    > "$TMP/green.log"
printf '%s\n' \
    "◇ Test run started." \
    "Suite WikiFSAppTests.FooTests passed after 0.1 seconds." \
    > "$TMP/plain-started-no-unicode-summary.log"

echo "test_run_summary_gate_assert — acceptance:"
expect_gate_ok "accepts equal started and summary counts" "$TMP/green.log"
cat > "$TMP/with-failure.log" <<'EOF'
◇ Test run started.
◇ Test run with 10 tests failed after 3.0 seconds.
EOF
expect_gate_ok "accepts one started run with one failed summary" "$TMP/with-failure.log"

echo "test_run_summary_gate_assert — the #1422 forced-deficit shapes:"
# The mid-run death shape: a started header with no summary for that bundle.
cat > "$TMP/deficit.log" <<'EOF'
◇ Test run started.
Suite WikiFSAppTests.SomeSuite passed after 0.1 seconds.
Suite WikiFSAppTests.OtherSuite passed after 0.2 seconds.
◇ Test run started.
◇ Test run with 120 tests passed after 12.0 seconds.
EOF
expect_gate_fails "fails when a started run never summarizes (1 of 2)" "$TMP/deficit.log"
expect_gate_fails "fails on a started header with no summary at all" "$TMP/plain-started-no-unicode-summary.log"

echo "test_run_summary_gate_assert — empty and missing logs:"
: > "$TMP/empty.log"
expect_gate_fails "fails on a log with no test-run lines (vacuous invocation)" "$TMP/empty.log"
expect_gate_fails "fails on a missing log file" "$TMP/does-not-exist.log"

echo "test_run_summary_gate_assert — loud failure carries the diagnosis:"
OUTPUT="$(test_run_summary_gate_assert "$TMP/deficit.log" "diagnostic" 2>&1)"
case "$OUTPUT" in
    *"2 test run(s) started"*"only 1 produced a run summary"*"false green"*)
        pass "deficit message names the counts and the false-green verdict" ;;
    *) fail "deficit message names the counts and the false-green verdict"; echo "$OUTPUT" | head -5 ;;
esac
case "$OUTPUT" in
    *"swiftpm-testing-helper crash report"*) pass "deficit message points at DiagnosticReports triage" ;;
    *) fail "deficit message points at DiagnosticReports triage" ;;
esac

echo
echo "assertions: ${ASSERTIONS}, failures: ${FAILURES}"
if [ "$FAILURES" -ne 0 ]; then exit 1; fi
echo "✓ run summary gate: all unit tests pass."
