---
timestamp: 2026-07-18T210442Z
title: "2026-07-18 — Fix missing activity ingestion details: thinking-level dropped in enrichment (branch `fix/missing-activity-details`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Fix missing activity ingestion details: thinking-level dropped in enrichment (branch `fix/missing-activity-details`)

## Progress


**Problem:** The Activity window lost the thinking-effort level segment ("high"/"medium"/"low") for completed ingestion/lint runs. The user reported that rich run metadata (model name, token counts, cost, timing) had partially regressed — the thinking-effort segment introduced in #566 was always blank.

**Root cause:** PR #569 (`Surface thinking effort level in UI`) added `thinkingLevel: String?` to `SessionUsage` and wired it through `ACPBackend.sessionUsage(for:)` and `UsageFormatter.fullSummary`, but the enrichment hop in `AgentLauncher.capturePhaseUsage` (which reattaches the configured `providerLabel`) reconstructed `SessionUsage` with an explicit memberwise init that omitted the `thinkingLevel` parameter — defaulting it to `nil` on every call. Since every `capturePhaseUsage` call site passes a non-nil `providerLabel`, the `if let providerLabel` branch always ran, and `thinkingLevel` was always lost. `SessionUsage.merging` then propagated `nil` through `runTotalUsage` → `onUsage` → the `.usage` queue event → `QueueActivityTracker.itemUsage`, so the Activity window's `fullSummary` rendered without the thinking-effort segment.

**Investigation (pipeline trace):** Verified the full usage pipeline is structurally intact — `ACPBackend.sessionUsage` → `capturePhaseUsage` → `runTotalUsage` → `AppQueueIngestionProvider.onUsage?(launcher.runTotalUsage)` × 3 sites → `emitUsage` → `QueueEngine.makeEmitUsage` broadcaster → `QueueActivityTracker.handle(.usage)` → `itemUsage` → `ActivityWindowView.fullSummary`. The display code (row + header) is present and correct. The #565/#571/#572/#573 merges did not break the wiring in `WikiFSApp.swift` (the `UsageEmitBox` seam). The only dropped field was `thinkingLevel` in `capturePhaseUsage`.

**Fix:** One-line addition — pass `thinkingLevel: usage.thinkingLevel` through the enrichment `SessionUsage` init in `capturePhaseUsage`. The `else` branch (no `providerLabel`) already passed `usage` directly. Added 3 regression tests covering `SessionUsage.merging` thinking-level latest-wins + existing-preserved, and `UsageFormatter.fullSummary` thinking-level inclusion between model and tokens.

Changes:
- `Sources/WikiFSEngine/AgentLauncher.swift` (`capturePhaseUsage`) — pass `thinkingLevel: usage.thinkingLevel` in the providerLabel enrichment init.
- `Tests/WikiFSTests/ACPBackendTests.swift` — added `thinkingLevel: "high"` assertion to `sessionUsageStructCarriesAllFields`; 2 new tests (`mergingCarriesLatestThinkingLevel`, `mergingPreservesExistingThinkingLevelWhenNewIsNil`).
- `Tests/WikiFSTests/UsageFormatterTests.swift` — 2 new tests (`fullSummaryIncludesThinkingLevelBetweenModelAndTokens`, `fullSummaryOmitsThinkingLevelWhenNil`).

**Build/Tests:** `make version prompts && swift build` clean; `swift test --filter UsageFormatterTests|ACPBackendTests` 67/67 pass; full fast test tier **2552 tests / 216 suites pass**.

## Verification

Historical verification remains in the progress record above.
