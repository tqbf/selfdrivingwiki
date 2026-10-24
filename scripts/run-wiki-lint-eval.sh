#!/bin/bash
# The lint evaluation harness entry point (plan phase 6). Deterministic
# commands only — `run --live` is refused by the runner without the flag
# and stays blocked until the operator confirms provider access, budget,
# and human rubric review.
set -euo pipefail

RUNNER=$(swift build --product WikiLintEvalRunner >/dev/null 2>&1 && \
  swift build --show-bin-path)/WikiLintEvalRunner

MANIFEST="${1:-Sources/WikiLintEval/Fixtures/canonical-gate-manifest.json}"

case "${2:-inspect}" in
  inspect)
    "$RUNNER" inspect --manifest "$MANIFEST"
    ;;
  replay)
    shift 2 || true
    "$RUNNER" replay --manifest "$MANIFEST" "$@"
    ;;
  *)
    echo "usage: scripts/run-wiki-lint-eval.sh [manifest] [inspect|replay ...]" >&2
    echo "      live evaluation: WikiLintEvalRunner run --live --gate (spends quota; blocked)" >&2
    exit 2
    ;;
esac
