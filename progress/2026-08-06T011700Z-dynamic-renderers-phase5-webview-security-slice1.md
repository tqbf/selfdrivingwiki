---
timestamp: 2026-08-06T011700Z
title: Dynamic renderers Phase 5 WebView security Slice 1
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 WebView security Slice 1

## Progress

- Added the renderer-package URL scheme and a version-pinned resource provider.
- The provider revalidates the installed package before each response.
- The provider accepts only manifest-declared relative assets.
- The provider checks the package ID, version, package hash, file identity, and asset hash.
- The provider opens each served asset without following links.
- Added a closed MIME policy. Unknown asset extensions fail closed.
- Added a WebKit scheme handler and task registry. The handler sends CSP, MIME,
  and nosniff headers before body bytes.
- The registry cancels and releases all registered tasks when it closes.
- This slice does not add a renderer session, WebKit storage policy, bridge,
  navigation policy, network harness, trusted activation, safe mode, SwiftUI
  host, Excalidraw, JSON Canvas, or settings UI.

## Verification

- `make build` passed on Swift 6.3.3.
- `swift test --filter RendererPackageResourceProviderTests --jobs 4` passed:
  4 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter RendererPackageSchemeHandlerTests --jobs 4`
  passed: 3 tests.
