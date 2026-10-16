#!/bin/bash
# Guarded entry point for the opt-in app test tier with mid-run death
# detection (#1422).
#
# Usage:
#   scripts/test-optin-app-tests-reconciled.sh [--expect REGEX] [swift test args...]
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
# The executed-evidence gate (#1427) and run-summary gate (#1431) both
# inspect this invocation's log. For a filtered run, pass --expect REGEX with
# an app suite expected to execute; an unfiltered run expects the sentinel.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

EXPECT=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --expect)
            if [ $# -lt 2 ]; then
                echo "✗ --expect requires a regex argument" >&2
                exit 2
            fi
            EXPECT="$2"
            shift 2
            ;;
        --expect=*)
            EXPECT="${1#--expect=}"
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
if [ -n "$EXPECT" ]; then
    export OPTIN_TEST_EXPECT="$EXPECT"
fi

# This script's contract IS the opt-in tier; setting the flag here makes the
# invocation self-contained instead of requiring an env prefix that can be
# forgotten or stripped.
export WIKIFS_APP_TESTS=1

WORKERS="${SWIFT_TEST_NUM_WORKERS:-1}"
LOG_DIR="tmp/test-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/optin-app-tests-reconciled-$(date +%Y%m%d-%H%M%S).log"

echo "==> swift test --parallel --num-workers ${WORKERS} ${ARGS[*]+"${ARGS[*]}"} (WIKIFS_APP_TESTS=1)"
echo "==> log: $LOG_FILE"

set -o pipefail
swift test --parallel --num-workers "$WORKERS" ${ARGS[@]+"${ARGS[@]}"} 2>&1 | tee "$LOG_FILE"
STATUS=$?

source "$REPO_ROOT/scripts/lib/optin-app-test-gate.sh"
if optin_gate_assert_executed "$LOG_FILE" "test-optin-app-tests-reconciled"; then
    OPTIN_GATE_OK=1
else
    OPTIN_GATE_OK=0
fi

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
if [ "$GATE_OK" -ne 1 ] || [ "$OPTIN_GATE_OK" -ne 1 ]; then
    echo "==> Exiting 1 (opt-in execution or run-summary gate failed)."
    exit 1
fi

echo "==> ✓ opt-in execution and run-summary gates passed."
exit 0
