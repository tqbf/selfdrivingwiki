#!/usr/bin/env bash
#
# benchmark-app-daemon-grpc.sh — the local paired benchmark for the
# app↔daemon transport budget (AC.6). NOT a hosted-CI gate: run on a QUIET
# developer Mac and record both runs in the progress note before cutover.
#
# Budget (approved plan): cold connect, page open, search, and queue round
# trip over gRPC must stay within the greater of 1.25× the XPC baseline or
# the measured noise floor.
#
# What this script does today:
#   1. Verifies the harness prerequisites (signed app, quiet-machine
#      checks, no runaway CPU).
#   2. Runs the paired measurement harness (swift test filter
#      AppDaemonTransportBudget in WikiFSAppTests) once per transport,
#      writing JSON samples to tmp/benchmark-app-daemon-grpc/.
#   3. Compares against the recorded baseline (progress note) and fails on
#      budget breach.
#
# The measurement harness lands with the family-migration PR (the gRPC
# route must carry real workload for the comparison to mean something).
# Until then this script exits non-success with an explicit NOT-READY
# marker so the gate cannot silently pass.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/tmp/benchmark-app-daemon-grpc"

log() { printf '%s\n' "$*"; }
fail() { printf 'benchmark-app-daemon-grpc: FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT"

# Quiet-machine check: load average below the CPU count, no runaway
# build processes. A busy machine invalidates the noise floor.
CPUS="$(sysctl -n hw.ncpu)"
LOAD="$(sysctl -n vm.loadavg | awk '{print $3}')"
if awk "BEGIN{exit !($LOAD > $CPUS)}"; then
  fail "load average $LOAD exceeds CPU count $CPUS — run on a quiet Mac"
fi

log "quiet machine: load $LOAD / $CPUS cpus"
log "NOT READY: the paired measurement harness (AppDaemonTransportBudget) lands"
log "with the family-migration PR, when the gRPC route carries real workload."
log "This gate cannot pass before then, by construction."
exit 3
