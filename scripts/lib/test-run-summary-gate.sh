#!/bin/bash
# Started-vs-summary reconciliation for `swift test` runs (#1422).
#
# When a swiftpm-testing-helper dies mid-run (the #1422 crash family: the
# helper was killed by EXC_GUARD (CLOSE) while closing a file descriptor
# that libsqlite3 had guarded — see the crash-report analysis on the issue),
# `swift test` still exits 0: the dead bundle printed its "Test run started."
# header but never reaches a "Test run with ... " summary, and the parent
# reports success for the whole invocation. Hundreds of planned tests are
# dropped with a green exit code.
#
# Contract enforced here: in the run log, every "Test run started" line must
# have a matching run summary line. Any deficit fails the invocation loudly,
# even when `swift test` exited 0. A log with NEITHER line shape is also a
# failure: an invocation that demonstrably ran no test bundle must not be
# presented as verified.
#
# Line shapes on this toolchain (Apple Swift 6.4, swift-testing):
#   ◇ Test run started.
#   ◇ Test run with 2855 tests passed after 845.2 seconds.
# The counting greps use the stable substrings "Test run started" and
# "Test run with", so the leading Unicode glyph or any verbose prefix does
# not affect the count.
#
# Stacking with #1427: that PR's executed-evidence gate
# (scripts/lib/optin-app-test-gate.sh) proves the opt-in target EXECUTED at
# least one test; this gate proves every STARTED test run FINISHED. #1427
# was open and unmerged when this file shipped, so the two are independent:
# neither sources the other, both take (log file, label), and a runner can
# apply both to the same log.

# The gate. Args: <log-file> <label>. Returns 1 and prints a loud,
# actionable failure when the log shows a summary deficit (or no test-run
# lines at all). Prints the reconciled counts on every path.
test_run_summary_gate_assert() {
    local log_file="$1"
    local label="$2"
    if [ ! -f "$log_file" ]; then
        echo ""
        echo "✗ RUN SUMMARY GATE FAILURE (#1422)"
        echo "  Run log not found: ${log_file}"
        echo "  There is nothing to reconcile, so the invocation cannot be"
        echo "  trusted. This is a gate wiring bug, not a test result."
        return 1
    fi
    local started summaries
    started="$(grep -c "Test run started" "$log_file")"
    summaries="$(grep -c "Test run with" "$log_file")"

    echo "==> run summary gate: label=${label} started=${started} summaries=${summaries} log=${log_file}"

    if [ "$started" -eq 0 ] && [ "$summaries" -eq 0 ]; then
        echo ""
        echo "✗ RUN SUMMARY GATE FAILURE (#1422)"
        echo "  The run log contains no \"Test run started\" and no"
        echo "  \"Test run with\" lines — no test bundle demonstrably ran."
        echo "  This invocation is a false green; do not trust exit 0."
        echo ""
        echo "  Last 20 log lines for triage:"
        tail -20 "$log_file" | sed 's/^/    /'
        return 1
    fi

    if [ "$started" -gt "$summaries" ]; then
        local deficit=$((started - summaries))
        echo ""
        echo "✗ RUN SUMMARY GATE FAILURE (#1422): ${started} test run(s) started"
        echo "  but only ${summaries} produced a run summary (deficit: ${deficit})."
        echo "  A test bundle's runner died mid-run (or its output was lost)"
        echo "  and swift test still exited 0. Every test planned by the"
        echo "  un-summarized run was silently dropped; this invocation is a"
        echo "  false green. Check ~/Library/Logs/DiagnosticReports/ for a"
        echo "  swiftpm-testing-helper crash report written during this run."
        echo ""
        echo "  Last 20 log lines for triage:"
        tail -20 "$log_file" | sed 's/^/    /'
        return 1
    fi

    return 0
}
