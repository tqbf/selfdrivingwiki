---
timestamp: 2026-08-06T060000Z
title: Dynamic renderers Phase 5 WebView session lifecycle
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 WebView session lifecycle

## Progress

- Added the WebView session policy and session state machine.
- Added a fresh WebKit configuration for each renderer session.
- Each configuration uses a new nonpersistent website data store.
- Each configuration has a new user content controller and package scheme handler.
- Each configuration has one named isolated content world.
- The session starts only a renderer-package URL request.
- The session does not use file URLs, loadFileURL, or loadHTMLString.
- The session cancels its timeout and owned operations when it closes.
- The session closes package scheme tasks before it releases WebKit references.
- This slice does not add bridge authorization, input.read, navigation policy,
  trusted activation, a network harness, safe mode, a SwiftUI host,
  Excalidraw, JSON Canvas, or settings UI.

## Verification

- `make build` passed on Swift 6.3.3.
- The focused session contract and opt-in WebKit tests passed.
- `make lint`, the inventory check, and `git diff --check` passed.
