---
timestamp: 2026-07-21T125312Z
title: "2026-07-20 — Fix swift CI: build+cache fixed; test hang addressed (branch `ci-speedup`, PR #732)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Fix swift CI: build+cache fixed; test hang addressed (branch `ci-speedup`, PR #732)

## Progress


**Outcome.** Build + cache + test steps all green in CI. The test hang that
timed out CI at 30 min was a **cooperative thread pool starvation** caused by
blocking calls (`Thread.sleep`, `Process.waitUntilExit()`) in `@MainActor` and
`--parallel` test suites. On CI's 3-vCPU runner, a few blocking calls exhaust
the pool and deadlock every other test.

**Root cause.** The last successful CI (July 19, `95123a80`) used a 2-tier
approach with a SKIP list for heavy suites. Commit `5101e42` removed the tiers,
running the full suite in one job. The in-memory fixtures (#658) fixed the
*speed* but not the *blocking* — `Thread.sleep(6)` in `PageVersionTests`
(blocks the main actor for 6s) and `waitUntilExit()` in `PdfExtractionServiceTests`
(parks a cooperative pool thread) starve the pool on constrained CI runners.

**Fix.**
- Replaced all `Thread.sleep` in tests with `Task.sleep` (non-blocking):
  `PageVersionTests.amendAfterWindowExpiresAppends` (6s → `.seconds(6)`),
  `ChatSummaryTests.summaryBumpsUpdatedAt` (10ms), `NavigationHistoryTests`
  (2ms × 2 tests).
- Replaced all `Process.waitUntilExit()` in `PdfExtractionServiceTests` with
  a `terminationHandler` + `CheckedContinuation` wrapper (`asyncWaitUntilExit`)
  — same semantics, non-blocking.
- Added `.serialized, .timeLimit(.minutes(2))` to the 4 `CheckedContinuation`
  suites (`QueueExtractionTests`, `ACPTurnRecoveryTests`, `ACPWiringTests`,
  `QueueEngineTests`) as a safety net.
- Added `.serialized` to 2 WKWebView suites (`YouTubeEmbedWebViewTests`,
  `QuoteHighlightWebViewTests`).

**CI workflow changes.**
- Cache key on `Package.resolved` only (dropped `Sources/**/*.swift` hash +
  `restore-keys` that produced one cache entry per commit, blowing the 10 GB
  LRU).
- Plain `xcrun swift build` / `xcrun swift test --parallel` (removed the
  fragile `xcrun swift build 2>/dev/null` probe that masked build errors).

## Verification

Historical verification remains in the progress record above.
