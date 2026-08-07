---
timestamp: 2026-08-06T140000Z
title: Dynamic renderers Phase 5 SwiftUI host
branch: feature/dynamic-renderers-05-webview-security
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

- `swift build --disable-sandbox` passed after integration into the security branch at `c87ae322`.
- The commit hook ran strict SwiftLint across 481 files and found zero violations.
- The inventory resolver and `git diff --check` passed for the integrated file set.
- Focused host and session tests remain part of the final cumulative verification; live WebKit tests are opt-in through `WIKIFS_APP_TESTS=1`.
- `make build` may still be unavailable in this environment because its unchanged icon generation prerequisite uses `iconutil`; the direct SwiftPM build is the authoritative compile gate here.
- Hosted tests remain opt-in through `WIKIFS_APP_TESTS=1`. They mount a real `WKWebView` with a recording session. They do not load a renderer package or prove network isolation.
- The host seam is committed as `c87ae322df2122971423349f6269993cb4591967`; no push, merge, or retarget occurred.
