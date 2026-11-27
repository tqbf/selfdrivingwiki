#!/usr/bin/env bash
#
# test-signed-app-daemon-grpc.sh — the signed cold-launch smoke (AC.1,
# plans/app-daemon-wire-contract.md). Requires a developer Mac with
# signing/local.config; hosted CI cannot replace it.
#
# Procedure (first slice):
#   1. Preflight the signing config (signing/preflight.py).
#   2. Build + install the signed app (make install).
#   3. Launch the app, drive the first-slice flow through the bundled
#      daemon: on-demand launch → ListWikis → one live registry event →
#      daemon exit → reconnect to a NEW daemon instance.
#   4. Assert the fixture daemon PID has NO TCP listeners (lsof) — the
#      contract forbids a TCP listener, ever.
#
# The drive step uses the app's own UI automation hooks and lands with the
# harness work in the family-migration PR; until then this script performs
# the preflight + install + the TCP-listener audit against a manually
# launched app and exits with an explicit NOT-READY marker for the
# automated flow.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/build/Self Driving Wiki.app"

log() { printf '%s\n' "$*"; }
fail() { printf 'test-signed-app-daemon-grpc: FAIL: %s\n' "$*" >&2; exit 1; }

# 1. Signing preflight.
(cd "$REPO_ROOT" && python3 signing/preflight.py) \
  || fail "signing preflight failed (see signing/README.md)"

# 2. Built + signed app present.
[ -d "$APP" ] || fail "app not built; run make build first"
codesign --verify --deep --strict "$APP" \
  || fail "codesign verification failed for $APP"

# 3. TCP-listener audit: no wikid.xpc instance may hold a TCP socket while
#    this machine's app runs. The gRPC contract forbids TCP outright.
PIDS="$(pgrep -f wikid.xpc 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  for pid in $PIDS; do
    if lsof -p "$pid" 2>/dev/null | grep -E "TCP .* (LISTEN|ESTABLISHED)"; then
      fail "daemon PID $pid holds a TCP socket — contract violation"
    fi
  done
  log "TCP audit: clean for PIDs $PIDS"
else
  log "TCP audit: no running daemon instance found (launch the app first for the full flow)"
fi

log "Automated drive (launch → list → event → restart) lands with the"
log "family-migration PR harness. The preflight + TCP audit above run now;"
log "the full smoke needs the drive step to record AC.1 evidence."
exit 3
