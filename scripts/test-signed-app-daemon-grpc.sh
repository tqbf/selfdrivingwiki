#!/usr/bin/env bash
#
# test-signed-app-daemon-grpc.sh — the signed cold-launch smoke (AC.1,
# plans/app-daemon-wire-contract.md). Requires a developer Mac with
# signing/local.config; hosted CI cannot replace it.
#
# Flow:
#   1. Preflight the signing config (signing/preflight.py).
#   2. Build the signed app (make build). The launch step then REUSES
#      `make run` (install + open) so the smoke exercises the exact
#      documented dev launch path. Set SMOKE_SKIP_INSTALL=1 to skip the
#      reinstall and just open the existing /Applications copy.
#   3. Drive the full AC.1 flow with the AppDaemonSmoke binary: XPC
#      admission → gRPC session → ListWikis → live registry event →
#      verified daemon stop → reconnect to a NEW daemon instance.
#   4. Audit: no daemon PID may hold a TCP listener (the contract forbids
#      TCP), checked before and after the drive.
#
# NOTE: `make run` installs the app, which stops this machine's running
# app instance (the documented behavior). Run this when replacing the
# installed app is acceptable.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/build/Self Driving Wiki.app"
INSTALLED_APP="/Applications/$(basename "$APP")"
APP_GROUP="$(cd "$REPO_ROOT" && . signing/local.config >/dev/null 2>&1 && printf '%s' "$APP_GROUP")"

log() { printf '%s\n' "$*"; }
fail() { printf 'test-signed-app-daemon-grpc: FAIL: %s\n' "$*" >&2; exit 1; }

# 1. Signing preflight.
(cd "$REPO_ROOT" && python3 signing/preflight.py) \
  || fail "signing preflight failed (see signing/README.md)"

# 2. Build the signed app (both paths need it: `make run` installs the
#    build copy; SMOKE_SKIP_INSTALL still needs a fresh smoke binary).
log "== building the signed app"
(cd "$REPO_ROOT" && make build) || fail "make build failed"

# 3. Launch — REUSING make run for the default path.
if [ "${SMOKE_SKIP_INSTALL:-0}" = "1" ]; then
  log "== SMOKE_SKIP_INSTALL=1: opening the existing /Applications copy"
  [ -d "$INSTALLED_APP" ] \
    || fail "no installed app at $INSTALLED_APP (run without SMOKE_SKIP_INSTALL first)"
  open -n "$INSTALLED_APP" || fail "app launch failed"
else
  log "== make run (installs the signed app, stops the running instance, opens it)"
  (cd "$REPO_ROOT" && make run) || fail "make run failed"
fi
sleep 5

SMOKE_BIN="$REPO_ROOT/.build/out/Products/Debug/AppDaemonSmoke"
[ -x "$SMOKE_BIN" ] || SMOKE_BIN="$REPO_ROOT/.build/arm64-apple-macosx/debug/AppDaemonSmoke"
[ -x "$SMOKE_BIN" ] || fail "AppDaemonSmoke binary not built; run swift build --product AppDaemonSmoke"

# 4. TCP audit helper: no wikid.xpc PID may hold a TCP socket.
tcp_audit() {
  local phase="$1"
  local pids
  pids="$(pgrep -f wikid.xpc 2>/dev/null || true)"
  if [ -z "$pids" ]; then
    log "TCP audit ($phase): no daemon instance running"
    return 0
  fi
  for pid in $pids; do
    if lsof -p "$pid" 2>/dev/null | grep -E "TCP .* (LISTEN|ESTABLISHED)"; then
      fail "daemon PID $pid holds a TCP socket ($phase) — contract violation"
    fi
  done
  log "TCP audit ($phase): clean for PIDs $(echo "$pids" | tr '\n' ' ')"
}

tcp_audit "before drive"

# 5. The drive.
log "== driving XPC admission → gRPC session → list → event → stop → reconnect"
WIKI_APP_GROUP_ID="$APP_GROUP" "$SMOKE_BIN" || fail "smoke drive failed"

tcp_audit "after drive"
log "== AC.1 signed smoke PASSED"
