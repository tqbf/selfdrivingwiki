---
timestamp: 2026-08-06T090000Z
title: Dynamic renderers Phase 5 bridge slice
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 bridge slice

## Progress

- Added closed, bounded `input.read` bridge contracts with request replay rejection.
- Bound each request to its session capability, native window, and main frame.
- Added exact `SourceVersionID` byte reads and `SourceMarkdownVersionID` reads; the bridge does not call live `sourceContent(id:)`.
- Added the opt-in isolated-world broker and script-message adapter to the existing per-session WebKit configuration.
- This slice does not add trusted activation, navigation policy, network or storage harnesses, safe mode, a SwiftUI host, Excalidraw, JSON Canvas, or package-management UI.

## Verification

- Focused portable bridge and version-pinning tests passed.
- Hosted WebKit session tests, build, lint, documentation contract, inventory resolver, and diff checks are recorded with this branch head.
