#!/usr/bin/env bash
#
# scripts/test-signed-speech.sh — the gated signed-bundle speech diagnostic.
#
# Launches the PACKAGED app (build/WikiFS.app from `make build`, not
# SwiftPM's unsigned test host) via LaunchServices with an explicit
# diagnostic argument and a short-lived token, verifies the bundle identity
# and code signature, and asks the bundled wikid.xpc daemon to run the same
# local `say` fixture under ITS OWN identity. Only a bounded typed result
# crosses back (readiness + pass/fail + engine identity) — never transcript
# text, never paths.
#
# Usage:
#   scripts/test-signed-speech.sh [path/to/WikiFS.app]
#
# Exit 0 = both the app and daemon diagnostics reported typed readiness and
# a completed transcription check. Any other exit = a setup, signature, or
# diagnostic failure (fixed redacted reasons on stderr).

set -euo pipefail

APP="${1:-build/WikiFS.app}"
TOKEN="$(uuidgen)"
DAEMON_TIMEOUT_SECONDS=120

if [[ ! -d "$APP" ]]; then
  echo "error: $APP does not exist — run `make build` first" >&2
  exit 1
fi

# Bundle identity + signature verification: an unsigned or wrong-bundle
# target is rejected before anything launches.
PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "error: $APP has no Contents/Info.plist" >&2
  exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_ID" != org.sockpuppet.WikiFS* && "$BUNDLE_ID" != *WikiFS* ]]; then
  echo "error: unexpected bundle identifier '$BUNDLE_ID'" >&2
  exit 1
fi
if ! codesign --verify --strict "$APP" >/dev/null 2>&1; then
  echo "error: $APP is not validly code-signed; the speech diagnostic requires a signed bundle" >&2
  exit 1
fi
echo "✓ bundle identity: $BUNDLE_ID"
echo "✓ code signature verified"

# The diagnostic entry point is admitted before normal app startup: the
# launched app collects the bounded typed result on its local test channel
# and exits. It runs the fixture through its bundled daemon (wikid.xpc), so
# the daemon's own identity, permissions, and model assets are what is
# actually exercised.
echo "→ launching $APP with the speech diagnostic argument"
RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wiki-speech-diag.XXXXXX")"
trap 'rm -rf "$RESULT_DIR"' EXIT

# Non-blocking launch: the diagnostic result document is the completion
# signal (no shell-level process control — see the signal-safety audit).
open -n "$APP" --args \
  -wikiSpeechDiagnostic "$TOKEN" \
  -wikiSpeechDiagnosticResultDir "$RESULT_DIR"

# The app writes exactly one bounded JSON result document:
# { "app": {"ready": bool, "detail": string}, "daemon": {…}, "engine": string }
for _ in $(seq 1 "$DAEMON_TIMEOUT_SECONDS"); do
  if [[ -f "$RESULT_DIR/result.json" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "$RESULT_DIR/result.json" ]]; then
  echo "error: the diagnostic did not report within ${DAEMON_TIMEOUT_SECONDS}s" >&2
  exit 1
fi

python3 - "$RESULT_DIR/result.json" <<'PY'
import json, sys

result = json.load(open(sys.argv[1]))
for host in ("app", "daemon"):
    section = result.get(host) or {}
    if section.get("ready") is not True:
        print(f"error: {host} speech readiness failed: {section.get('detail', 'unready')}", file=sys.stderr)
        raise SystemExit(1)
    if section.get("transcribed") is not True:
        print(f"error: {host} fixture transcription did not complete: {section.get('detail', 'no result')}", file=sys.stderr)
        raise SystemExit(1)
engine = result.get("engine", "")
if not engine:
    print("error: the diagnostic reported no engine identity", file=sys.stderr)
    raise SystemExit(1)
print(f"✓ app diagnostic: ready, fixture transcribed")
print(f"✓ daemon diagnostic: ready, fixture transcribed")
print(f"✓ engine: {engine}")
PY

echo "✓ signed-bundle speech diagnostic passed"
