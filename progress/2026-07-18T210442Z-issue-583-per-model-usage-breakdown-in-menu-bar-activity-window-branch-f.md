---
timestamp: 2026-07-18T210442Z
title: "2026-07-18 — Issue #583: per-model usage breakdown in menu bar + Activity window (branch `feature/usage-breakdown-by-model`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Issue #583: per-model usage breakdown in menu bar + Activity window (branch `feature/usage-breakdown-by-model`)

## Progress


**Problem:** The menu bar's "Today: 76K tokens · $1.23" is a single aggregate. Token pricing/kind varies wildly per model, so the aggregate hides the real signal — a "76K" day could be one Opus run or thirty Sonnet runs.

**Fix:** Track usage per model id + input/output/thought, surface it in two places:
1. **Menu bar** — one disabled, indented, secondary-gray item per model below the summary line, heaviest first, unknown-model bucket last. `runCount > 1` appends " · N runs" so many-small-runs days read clearly.
2. **Activity window per-item detail** — a per-model sub-view (caption, tertiary) when a single run used more than one model. Today most runs have one entry (the launcher merges phases into one `runTotalUsage`), but the structure is ready for phase-level usage events.

**Data flow unchanged:** `ACPBackend.sessionUsage(for:)` → `AgentLauncher.capturePhaseUsage` → `runTotalUsage` → `.usage` queue event → `QueueActivityTracker.handle(.usage)`. The only new bits are an `itemUsageByModel` dict (in-memory, per-item) and a `todayUsageByModel: DailyUsageByModel` (persisted to `UserDefaults` with a daily-reset key, mirroring `DailyUsage`).

**SessionUsage grew a `modelName: String?` field.** Resolved at the `ACPBackend` seam by matching `currentModelId` against `ModelsInfo.availableModels.first(where: modelId match)?.name`. Falls back to `nil` when no list advertised, no entry matches, or the name is empty. Point-in-time (latest non-nil wins on merge), like `modelId`. `UsageFormatter.fullSummary` and the new `itemModelBreakdownLine` prefer `modelName` over `modelId` for display.

## Verification

Historical verification remains in the progress record above.
