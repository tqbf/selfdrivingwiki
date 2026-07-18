## Summary

Per-model usage breakdown for the menu bar + Activity window (issue #583).

The menu bar's "Today: 76K tokens · $1.23" line is a single aggregate. Token pricing/kind varies wildly across models — a "76K" day could be one Opus run or thirty Sonnet runs. This PR adds a per-model + per-token-kind (input/output/thought) breakdown visible in two places, without changing the existing aggregate display.

## What changed

### 1. `SessionUsage` grows a `modelName: String?` field

Already carried `modelId` (e.g. `"claude-sonnet-4-5-20250929"`); now also carries the friendly name (e.g. `"Claude Sonnet 4.5"`), resolved in `ACPBackend.sessionUsage(for:)` by matching `currentModelId` against `ModelsInfo.availableModels`. Falls back to `nil` when the agent didn't advertise a list or no entry matches. Point-in-time (latest non-nil wins on merge), like `modelId`. `UsageFormatter.fullSummary` prefers `modelName` over `modelId` for display.

### 2. Per-model accumulation in `QueueActivityTracker`

Two new structures:
- `ModelUsageBreakdown` — one model's per-day/per-run contribution (input/output/thought/total tokens, cost, currency, runCount). Mutex-free plain struct; accumulated on the main actor.
- `DailyUsageByModel` — daily per-model breakdown persisted to `UserDefaults` (`sdw_dailyUsageByModel_v1`) with a `yyyy-MM-dd` date key that resets daily. Mirrors `DailyUsage`'s lifecycle.

Added state: `itemUsageByModel` (per-item, in-memory), `todayUsageByModel` (daily, persisted). The `.usage` handler now accumulates into both alongside the existing `todayUsage` aggregate — no new event types, no data-flow change.

### 3. Menu bar rendering

`buildMenu` keeps the summary line unchanged and appends one disabled, indented, secondary-gray item per model below it, heaviest first (largest `totalTokens`), unknown-model bucket always last:

```
Today: 76K tokens · $1.23
    Sonnet 4 · 52K in · 8K out · 1.2K thought · $0.89
    Opus 4 · 12K in · 3K out · $0.34
─────────────────────────
```

`runCount > 1` appends " · N runs" so a per-model total composed of many small runs reads clearly. The menu bar doesn't hold `ModelsInfo.availableModels`, so the line uses the raw `modelId` as a fallback (the friendly-name hook is exposed via `displayNameProvider` but not wired — see Future work).

### 4. Activity window per-item detail

A per-model sub-view (caption, tertiary color) appears when a run's breakdown contains more than one model. Today most runs have a single entry (the launcher merges planner/executor/finalizer phases into one `runTotalUsage` before emitting the `.usage` event), so the multi-model branch lights up only once phase-level usage events land. Sorted the same way as `DailyUsageByModel.sortedForDisplay`.

### 5. Persistence

`DailyUsageByModel` mirrors `DailyUsage`: persisted after each `.usage` event, reset on the date-key check at load. Dictionary keyed by raw `modelId`; friendly name re-resolved at display time.

## Tests

12 new tests in `UsageFormatterTests`:
- `fullSummaryPrefersModelNameOverId` / `fullSummaryFallsBackToModelIdWhenNameIsNil`
- `modelBreakdownLineRendersAllSegments` / `...OmitsThoughtWhenZero` / `...AppendsRunCountWhenGreaterThanOne` / `...RendersUnknownBucket`
- `breakdownSumsTokensAndRunCountAcrossAdds` / `breakdownHasDataIsFalseWhenAllZero`
- `dailyByModelAccumulatesPerModelKey` / `...SortedForDisplayPutsHeaviestFirstAndUnknownLast`
- `itemModelLinePrefersModelNameFromUsage`

## Build / test status

- `make version prompts && swift build` — clean.
- Full fast test tier (`swift test --skip ...` per the CI fast-tier regex) — **2573 tests / 218 suites pass**.
- `swift test --filter UsageFormatterTests` — 40/40 pass.

## Design notes

- **Why inline disabled menu items (not a sub-menu or popover):** the issue spec's v1 recommendation was simplest, and matches macOS menu-bar convention for "read-only supporting detail" (e.g. the Wi-Fi menu signal-strength lines, Time Machine's "Oldest backup: …"). Indent + secondary-label color + disabled state make the group read as detail under the summary, not as primary content matching the summary's weight.
- **Why key by raw modelId (not the friendly name):** model names can shift between sessions, but a model id is stable across the daily partition. The friendly name is re-resolved at display time (today via `SessionUsage.modelName`; future work: a `displayNameProvider` lookup against `AgentProvidersConfig.providerModels`).
- **Why the unknown-model bucket:** the backend doesn't always report a `modelId` (non-ACP backends, older agents, pre-session-start failures). Tracking these under `"__unknown__"` keeps the per-model totals reconcilable against the aggregate — otherwise "unknown" usage would silently disappear from the breakdown but still count in the summary, which reads like a bug.
- **Why `runCount > 1` appends " · N runs":** without it, the user can't tell whether "52K in · $0.89" came from one long Sonnet run or thirty small ones — and that's exactly the signal the flat aggregate was hiding.

## Future work

- **Per-phase usage events.** Today the launcher merges all phase snapshots into one `runTotalUsage` before emitting one `.usage` event. When phases start emitting individual events, `itemUsageByModel` lights up as a real per-run multi-model breakdown and the `byModel.count > 1` branch in the Activity window activates with no code change.
- **Friendly-name lookup at the menu bar.** `UsageFormatter.modelBreakdownLine`'s `displayNameProvider` hook is ready — wire it to the `AgentProvidersConfig.providerModels` cache so the menu bar shows "Claude Sonnet 4.5" instead of "claude-sonnet-4-5-20250929".
- **Interactive chat usage (#546/#576 path).** The tracker's `.usage` handler is model-agnostic; once interactive turns emit `.usage` events per turn, they'll flow through this same per-model accumulator with no code change.

Design rationale + future work: `plans/usage-breakdown-by-model.md`.
