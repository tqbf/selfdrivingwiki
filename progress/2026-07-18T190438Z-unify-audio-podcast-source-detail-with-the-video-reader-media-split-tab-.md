---
timestamp: 2026-07-18T190438Z
title: "2026-07-18 — Unify audio podcast source detail with the video Reader/Media/Split tab pattern (branch `feature/audio-podcast-detail-tabs`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Unify audio podcast source detail with the video Reader/Media/Split tab pattern (branch `feature/audio-podcast-detail-tabs`)

## Progress


**Problem.** PR #586 (open, `unify-video-pdf-source-tabs`) unified *video*
sources (YouTube/Vimeo) into the same Reader / Video / Split tab layout that
PDFs use — but audio podcast sources (Apple Podcasts), which route through the
exact same `ExternalEmbed` byteless-embed path, would have surfaced under a
"Video" tab label. The tab system was video-specific in name; audio needed the
same Reader/Media/Split treatment with an "Audio" label.

**Fix.** Generalized the video tab into a media tab that classifies audio vs
video and labels the picker accordingly. Two files changed (one new pure
helper + view wiring, one test suite). Built on top of the merged #586 pattern
(video tab renamed → media tab).

Changes:
- `Sources/WikiFSEngine/ACPBackend.swift` — `SessionUsage.modelName` field + init param + merge propagation; `sessionUsage(for:)` resolves the friendly name from `ModelsInfo.availableModels`.
- `Sources/WikiFSEngine/AgentLauncher.swift` — `capturePhaseUsage` passes `modelName: usage.modelName` through the providerLabel enrichment init.
- `Sources/WikiFS/Queue/QueueActivityTracker.swift` — `ModelUsageBreakdown` struct, `DailyUsageByModel` persisted struct (load/save/sortedForDisplay), `itemUsageByModel` + `todayUsageByModel` state, `.usage` handler accumulation, `usageBreakdown(for:)` accessor, `UsageFormatter.modelBreakdownLine` + `itemModelBreakdownLine`.
- `Sources/WikiFS/Window/MenuBarItemController.swift` — `buildMenu` appends per-model items below the summary line.
- `Sources/WikiFS/Queue/ActivityWindowView.swift` — `detailHeader` per-model sub-view; `byModelSorted` helper.
- `Tests/WikiFSTests/UsageFormatterTests.swift` — 12 new tests (modelName preference, modelBreakdownLine variants, breakdown accumulation, DailyUsageByModel accumulation + sort, itemModelBreakdownLine).
- `plans/usage-breakdown-by-model.md` — design doc + future work (phase-level usage events, friendly-name lookup at the menu bar, interactive chat usage #546/#576).

**Build/Tests:** `make version prompts && swift build` clean; full fast test tier **2573 tests / 218 suites pass**; `swift test --filter UsageFormatterTests` 40/40 pass.

## Verification

Historical verification remains in the progress record above.
