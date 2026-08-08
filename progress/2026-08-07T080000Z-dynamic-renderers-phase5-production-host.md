---
timestamp: 2026-08-07T080000Z
title: Dynamic renderers Phase 5 production host wiring
branch: feature/dynamic-renderers-06-excalidraw-json-canvas
status: complete
---

# Dynamic renderers Phase 5 production host wiring

## Progress

The installed-renderer host now enters the app composition root. `WikiFSApp` owns one host instance and refreshes it after the first window appears. The host reads the machine index, revalidates installed package roots, and builds the factory inputs for validated package versions.

The host filters safe-mode-suppressed records before it creates providers. A missing store, a read error, or package revalidation failure leaves the factory unavailable. `SourceDetailView` then keeps its Source fallback.

The host exposes a typed reset method for one package and version. The reset method refreshes the host snapshot after a successful store update. It returns `false` when the store is unavailable or the reset fails.

## Follow-up host session wiring

The separately authorized follow-up at `1d01264a2b893c3c1e5a576d946dc318134799ea` connects an installed renderer to its active source version. `SourceDetailView` supplies a `RendererAuthorizedInputReader`. The factory rejects missing, unavailable, or oversized input before it starts a session.

The factory keeps the existing package reference and failure recorder. It gives the live session the existing trusted-link policy. The isolated bridge gets only the pinned input selector. The page does not get the session capability.

The existing representable still owns deferred failure delivery, replacement teardown, and Source fallback. The follow-up does not change the matcher, package validator, safe-mode policy, or WebKit security policy.

## Verification

Verification at implementation head `4cc6bde0`:

- `swift test --disable-sandbox --filter InstalledRendererHostTests --jobs 4` passed with 2 tests in 1 suite.
- `swiftc -parse Tests/WikiFSAppTests/InstalledRendererHostTests.swift` passed.
- Strict no-cache SwiftLint passed for the new host and test files.
- The inventory resolver passed in both directions.
- `git diff --check` passed.

The focused test does not exercise a real installed package or a live WebKit document. Hosted WebKit and package-store integration remain separate gates.

Verification at follow-up implementation head `1d01264a2b893c3c1e5a576d946dc318134799ea`:

- `WIKIFS_APP_TESTS=1 swift test --filter WikiAppWebViewTests --jobs 4` passed with 9 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter RendererContentWorldBridgeTests --jobs 4` passed with 5 tests.
- `swift test --filter RendererAuthorizedInputReaderTests --jobs 4` passed with 2 tests.
- `WIKIFS_APP_TESTS=1 swift test --filter 'WikiAppWebViewSessionTests|RendererContentWorldBridgeTests' --jobs 4` passed with 20 tests.
- `make lint`, `swift build --jobs 4`, and `swift test --jobs 4` passed.
- `swiftc -parse` and `git diff --check` passed for the tracked host-wiring paths.

The hosted factory test uses a recording session. It does not load a real installed package document. The protected untracked Excalidraw package work was not inspected, changed, staged, or committed.
