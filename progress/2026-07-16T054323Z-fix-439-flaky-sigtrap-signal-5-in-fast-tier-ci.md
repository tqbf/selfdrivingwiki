---
timestamp: 2026-07-16T054323Z
title: "2026-07-15 — Fix #439: flaky SIGTRAP (signal 5) in fast-tier CI"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-15 — Fix #439: flaky SIGTRAP (signal 5) in fast-tier CI

## Progress


**Problem:** The fast-tier `swift` CI job intermittently crashed with
`Exited with unexpected signal code 5` (SIGTRAP) on `macos-latest`, killing
the parallel test process. Root cause: two suites instantiate
`WKWebView`/`NSWindow` off a host app — `SplitDiffSnapshotTests` (renders
`WKWebView`/`NSHostingController` to PNG snapshots) and
`QuoteHighlightWebViewTests` (bare `WKWebView` + JS eval). Headless macOS GH
Actions runners SIGTRAP on AppKit/WebKit under `swift test`'s concurrent
execution. A secondary `ChatStoreTests.chatMessagesSkipsRowWithCorruptEventJSON`
WAL-lock failure was a telemetry side-effect of the crash teardown, not a bug.

**Fix:** Moved both suites to the `swift-integration` (full-suite) job only —
they still gate merges there, but no longer run in the per-commit fast tier.
- Tagged both suite types with `@Suite(.tags(.integration))` (matches the
  established pattern in `TestTags.swift`; documents intent + enables IDE/
  xcodebuild filtering; future-proofs for SwiftPM `--skip` tag support).
- Appended `SplitDiffSnapshotTests|QuoteHighlightWebViewTests` to the
  fast-tier `SKIP` env regex in `.github/workflows/ci.yml` (the actual skip
  mechanism — SwiftPM `--skip` is name-regex, not tag-based).

**Scope note:** Three other suites (`SidebarSelectAllShortcutTests`,
`ComposerTextViewTests`, `AddressBarLayoutHostedTests`) instantiate `NSWindow`
only (no `WKWebView`) for layout/shortcut testing — lighter, not observed to
crash, left in the fast tier per issue #439's stated scope.

**Build:** `make build` clean; the two suites now skip in the fast tier and run
in `swift-integration`.

---

## Verification

Historical verification remains in the progress record above.
