#!/bin/bash
# Guarded entry point for the opt-in app test tier with mid-run death
# detection (#1422).
#
# Usage:
#   scripts/test-optin-app-tests-reconciled.sh [swift test args...]
#   SWIFT_TEST_NUM_WORKERS=2 scripts/test-optin-app-tests-reconciled.sh
#
# The script sets WIKIFS_APP_TESTS=1 itself, runs `swift test --parallel
# --num-workers N` with the given extra arguments (default: none — the full
# opt-in graph), tees the log to
# tmp/test-logs/optin-app-tests-reconciled-<timestamp>.log, and then enforces
# the #1422 run-summary gate: every "Test run started" line in the log must
# have a matching run summary. When a swiftpm-testing-helper dies mid-run,
# `swift test` can exit 0 while the dead bundle's tests are silently dropped;
# this invocation then FAILS loudly with the reconciled counts instead of
# reporting a false green.
#
# Exit codes: 0 — swift test passed AND every started test run summarized.
# Nonzero — swift test failed, or the gate found a summary deficit (or an
# empty log).
#
# Stacking with #1427 (opt-in gate, executed-evidence): #1427 was open and
# unmerged when this script shipped. Its runner
# (scripts/test-optin-app-tests.sh) proves the opt-in target executed at
# least one test; this runner proves every started run finished. When #1427
# merges, the two gates can be applied to the same log — neither depends on
# the other, and this script deliberately does not source #1427's library
# (its sentinel test does not exist on main).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# This script's contract IS the opt-in tier; setting the flag here makes the
# invocation self-contained instead of requiring an env prefix that can be
# forgotten or stripped.
export WIKIFS_APP_TESTS=1

WORKERS="${SWIFT_TEST_NUM_WORKERS:-1}"
LOG_DIR="tmp/test-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/optin-app-tests-reconciled-$(date +%Y%m%d-%H%M%S).log"

echo "==> swift test --parallel --num-workers ${WORKERS} $* (WIKIFS_APP_TESTS=1)"
echo "==> log: $LOG_FILE"

set -o pipefail
swift test --parallel --num-workers "$WORKERS" "$@" 2>&1 | tee "$LOG_FILE"
STATUS=$?

source "$REPO_ROOT/scripts/lib/test-run-summary-gate.sh"
if test_run_summary_gate_assert "$LOG_FILE" "test-optin-app-tests-reconciled"; then
    GATE_OK=1
else
    GATE_OK=0
fi

if [ "$STATUS" -ne 0 ]; then
    echo "==> Exiting ${STATUS} (swift test failed)."
    exit "$STATUS"
fi
if [ "$GATE_OK" -ne 1 ]; then
    echo "==> Exiting 1 (run summary gate: a started test run never summarized — #1422)."
    exit 1
fi

echo "==> ✓ run summary gate passed: every started test run produced a summary."
exit 0
