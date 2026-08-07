---
timestamp: 2026-08-07T080000Z
title: Dynamic renderers Phase 5 production host wiring
branch: feature/dynamic-renderers-05-webview-security
status: complete
---

# Dynamic renderers Phase 5 production host wiring

## Progress

The installed-renderer host now enters the app composition root. `WikiFSApp` owns one host instance and refreshes it after the first window appears. The host reads the machine index, revalidates installed package roots, and builds the factory inputs for validated package versions.

The host filters safe-mode-suppressed records before it creates providers. A missing store, a read error, or package revalidation failure leaves the factory unavailable. `SourceDetailView` then keeps its Source fallback.

The host exposes a typed reset method for one package and version. The reset method refreshes the host snapshot after a successful store update. It returns `false` when the store is unavailable or the reset fails.

## Verification

Verification at implementation head `4cc6bde0`:

- `swift test --disable-sandbox --filter InstalledRendererHostTests --jobs 4` passed with 2 tests in 1 suite.
- `swiftc -parse Tests/WikiFSAppTests/InstalledRendererHostTests.swift` passed.
- Strict no-cache SwiftLint passed for the new host and test files.
- The inventory resolver passed in both directions.
- `git diff --check` passed.

The focused test does not exercise a real installed package or a live WebKit document. Hosted WebKit and package-store integration remain separate gates.
