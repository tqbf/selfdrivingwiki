---
timestamp: 2026-08-06T140000Z
title: Dynamic renderers Phase 5 SwiftUI host
branch: feature/dynamic-renderers-05-webview-swiftui-host
status: complete
---

# Dynamic renderers Phase 5 SwiftUI host

## Progress

- Added `WikiAppWebView` and `WikiAppWebViewRepresentable` for installed renderer sessions.
- Kept WebView, session, and delegate ownership on the main actor.
- Deferred session starts and SwiftUI-facing session failures out of AppKit and WebKit callbacks.
- Closed a previous session before a replacement starts. Dismantle closes the active session and removes its hosted view.
- Added a peer `InstalledRendererFactory`. The built-in factory remains a closed native renderer map.
- Added an injected installed-renderer snapshot seam. The default is unavailable, so Source remains the fallback until the app composition root supplies a validated package snapshot.
- Kept a failed installed renderer transient. A Source fallback does not remove a stored renderer preference. An explicit renderer selection clears the transient failure marker and retries with a new session.
- Did not add renderer settings, package picker or removal UI, Excalidraw, JSON Canvas, network changes, or storage changes.

## Verification

- `swiftc -parse` passed for all owned Swift production and test files.
- `swiftlint --strict --no-cache` passed for all owned Swift production and test files.
- The inventory resolver and `git diff --check` passed.
- The focused SwiftPM test command did not run. This fresh isolated worktree has no dependency checkout, and dependency fetching was intentionally not requested.
- `make build` did not run. Its unrelated icon generation prerequisite uses `iconutil`, which has an environment limitation. This slice does not wait on that tool.
- Hosted tests remain opt-in through `WIKIFS_APP_TESTS=1`. They mount a real `WKWebView` with a recording session. They do not load a renderer package or prove network isolation.
- Git could not stage the owned paths with the requested project-local index. The protected worktree Git object database rejected blob creation. No commit was created.
