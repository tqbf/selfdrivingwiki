---
timestamp: 2026-08-06T070000Z
title: Dynamic renderers Phase 5 WebView lifecycle remediation
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 WebView lifecycle remediation

## Progress

- The default session permit pool now applies to all renderer sessions.
- A failed load releases the WebView, configuration, scheme handler, and permit.
- A timeout records a load-timeout failure before resource cleanup.
- The session closes only when a caller requests close.
- A timeout callback checks its request generation before it changes session state.
- Each session now creates a named isolated content world with its session ID.
- The lifecycle tests cover global capacity, failure cleanup, stale timeouts,
  and discarded sessions.
- This change does not add navigation policy, bridge authorization, trusted
  activation, a network harness, safe mode, a SwiftUI host, or renderer UI.

## Verification

- `make build` and `make check` passed.
- The focused lifecycle and documentation tests passed.
- `make lint`, inventory resolution, and `git diff --check` passed.
