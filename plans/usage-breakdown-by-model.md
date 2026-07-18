# Per-model usage breakdown (#583)

**Status: shipped (feature/usage-breakdown-by-model).**

The menu bar's "Today: 76K tokens · $1.23" line is an aggregate across all
models a session used. Since token pricing and token kinds (input/output/
thought) vary wildly by model, the aggregate hides the real signal — a
day that looks "76K" could be one Opus run or thirty Sonnet runs. This
doc adds a per-model + per-token-kind breakdown visible in both the menu
bar and the Activity window.

## Data flow

```
ACPBackend.sessionUsage(for:)         ── resolves currentModelId + friendly name
   │                                    (ModelsInfo.availableModels match)
   ↓
AgentLauncher.capturePhaseUsage       ── enriches with providerLabel, threads modelName
   │
   ↓
runTotalUsage (merged)                ── emitted as one .usage queue event per run
   │
   ↓ (UsageEmitBox → QueueEngine.makeEmitUsage → broadcaster.yield(.usage))
QueueActivityTracker.handle(.usage):
   - itemUsage[id] = usage                       (existing, unchanged)
   - itemUsageByModel[id][modelKey] += usage    (new #583)
   - todayUsage += usage                        (existing)
   - todayUsageByModel[modelKey] += usage       (new #583)
   - DailyUsageByModel.save(todayUsageByModel)  (UserDefaults)
```

## SessionUsage grows a modelName field

`SessionUsage` previously carried `modelId` (the raw id like
`"claude-sonnet-4-5-20250929"`). #583 adds `modelName: String?` — the
friendly label the agent advertised (`"Claude Sonnet 4.5"`), resolved in
`ACPBackend.sessionUsage(for:)` by matching `currentModelId` against
`ModelsInfo.availableModels`. Falls back to `nil` when the agent didn't
advertise a list (older agents) or no entry matches — callers fall back
to `modelId` for display. Like `modelId`, it's point-in-time: latest
non-nil wins in `SessionUsage.merging`.

## Per-model structures

```swift
struct ModelUsageBreakdown: Codable, Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var thoughtTokens: Int = 0
    var totalTokens: Int = 0
    var cost: Double = 0
    var currency: String = "USD"
    var runCount: Int = 0
    static let unknownModelKey = "__unknown__"
    mutating func add(_ usage: SessionUsage)
}
```

Two trackers live in `QueueActivityTracker`:

- **`itemUsageByModel: [QueueItem.ID: [String: ModelUsageBreakdown]]`** — per-run,
  in-memory only. The Activity window's per-item detail reads this to show a
  model breakdown line under the aggregate when a run used more than one model.
- **`todayUsageByModel: DailyUsageByModel`** — per-day, persisted to
  `UserDefaults` (`sdw_dailyUsageByModel_v1`) with a `yyyy-MM-dd` date key that
  resets at midnight. The menu bar reads `sortedForDisplay` to append one
  disabled menu item per model below the summary line.

## Menu bar rendering

`MenuBarItemController.buildMenu` keeps the existing summary line unchanged
and appends one disabled, indented, secondary-colored item per model below
it, heaviest first (largest `totalTokens`), unknown-model bucket always last:

```
Today: 76K tokens · $1.23
    Sonnet 4 · 52K in · 8K out · 1.2K thought · $0.89
    Opus 4 · 12K in · 3K out · $0.34
─────────────────────────
```

`runCount > 1` appends " · N runs" so the user can tell when many small runs
added up to a model's total (the signal a flat aggregate hides). The menu
bar doesn't hold `ModelsInfo.availableModels`, so the line renders the raw
`modelId` as a fallback (the friendly-name hook is exposed via
`displayNameProvider` but not wired today).

## Activity window detail

`ActivityWindowView.detailHeader(for:)` adds a per-model sub-view when a
run's breakdown contains more than one model (today most runs have one —
the multi-model branch lights up once phase-level usage events land). Sorted
the same way as `DailyUsageByModel.sortedForDisplay`. Uses
`UsageFormatter.itemModelBreakdownLine`, which prefers `SessionUsage.modelName`
for the label.

## Persistence

`DailyUsageByModel` mirrors `DailyUsage`'s shape and lifecycle: persisted to
`UserDefaults` after each `.usage` event, reset on the date-key check at
load. The dictionary is keyed by raw `modelId`; the friendly name is re-resolved at display time (the menu bar / Activity window).

## Tests

`Tests/WikiFSTests/UsageFormatterTests.swift` gains:
- `fullSummaryPrefersModelNameOverId` / `...FallsBackToModelIdWhenNameIsNil`
- `modelBreakdownLineRendersAllSegments` / `...OmitsThoughtWhenZero` /
  `...AppendsRunCountWhenGreaterThanOne` / `...RendersUnknownBucket`
- `breakdownSumsTokensAndRunCountAcrossAdds` / `...HasDataIsFalseWhenAllZero`
- `dailyByModelAccumulatesPerModelKey` / `...SortedForDisplayPutsHeaviestFirstAndUnknownLast`
- `itemModelLinePrefersModelNameFromUsage`

## Future work

- **Per-phase usage events.** Today the launcher merges all phase snapshots
  into one `runTotalUsage` before emitting the single `.usage` event. When
  phases (planner vs executor vs finalizer) emit individual usage events,
  `itemUsageByModel` lights up as a real multi-model breakdown per run and
  the `byModel.count > 1` branch in the Activity window activates.
- **Friendly-name lookup at the menu bar.** `modelBreakdownLine`'s
  `displayNameProvider` hook is ready — wire it to the
  `AgentProvidersConfig.providerModels` cache so the menu bar shows
  "Claude Sonnet 4.5" instead of "claude-sonnet-4-5-20250929".
- **Interactive chat usage (#546/#576 path).** The tracker's `.usage` handler
  is model-agnostic; once interactive turns emit `.usage` events per turn,
  they'll flow through this same per-model accumulator with no code change.
