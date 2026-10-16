#!/bin/bash
# Guarded entry point for the opt-in app test tier (WikiFSAppTests).
#
# Usage:
#   scripts/test-optin-app-tests.sh [--expect REGEX] [swift test args...]
#   make test-app                                   # full opt-in graph
#   WIKIFS_APP_TESTS=1 make test                    # same guarded path via `test`
#
# The script sets WIKIFS_APP_TESTS=1 itself, runs `swift test` with the given
# extra arguments (default: none — the full opt-in graph), tees the log to
# tmp/test-logs/optin-app-tests-<timestamp>.log, and then enforces the #1398
# gate: the run must contain evidence that the WikiFSAppTests target actually
# EXECUTED, or the invocation fails loudly — even when `swift test` exited 0.
#
# Default expectation: the sentinel test `WikiFSAppTests.OptInGateSentinelTests`
# ships inside the app target precisely so its executed line proves the target
# ran. When this invocation deliberately narrows the run (e.g.
# `--filter ChatFooTests`), pass `--expect REGEX` with a suite you expect to
# execute; a mismatch is a gate failure, matching the repo's evidence rule
# that a filter matching zero tests is a failure.
#
# Exit codes: 0 — swift test passed and the gate found execution evidence.
# Nonzero — swift test failed, or the gate found no executed evidence
# (the #1398 false-green shape).
#
# Related: #1422 — the app runner can additionally die MID-RUN with exit 0
# after executing some tests; executed-evidence counting cannot catch that
# (tests demonstrably ran) and needs its own missing-summary guard.

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

# This script's contract IS the opt-in tier; setting the flag here makes
# `make test-app` self-contained instead of requiring an env prefix that can
# be forgotten or stripped.
export WIKIFS_APP_TESTS=1

WORKERS="${SWIFT_TEST_NUM_WORKERS:-1}"
LOG_DIR="tmp/test-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/optin-app-tests-$(date +%Y%m%d-%H%M%S).log"

echo "==> swift test --parallel --num-workers ${WORKERS} ${ARGS[*]+"${ARGS[*]}"} (WIKIFS_APP_TESTS=1)"
echo "==> log: $LOG_FILE"

set -o pipefail
swift test --parallel --num-workers "$WORKERS" ${ARGS[@]+"${ARGS[@]}"} 2>&1 | tee "$LOG_FILE"
STATUS=$?

source "$REPO_ROOT/scripts/lib/optin-app-test-gate.sh"
if ! optin_gate_assert_executed "$LOG_FILE" "test-optin-app-tests"; then
    GATE_OK=0
else
    GATE_OK=1
fi

if [ "$STATUS" -ne 0 ]; then
    echo "==> Exiting ${STATUS} (swift test failed)."
    exit "$STATUS"
fi
if [ "$GATE_OK" -ne 1 ]; then
    echo "==> Exiting 1 (opt-in gate: no executed evidence for ${OPTIN_TEST_EXPECT:-WikiFSAppTests.OptInGateSentinelTests})."
    exit 1
fi

echo "==> ✓ opt-in gate passed: the app test target demonstrably executed."
exit 0
