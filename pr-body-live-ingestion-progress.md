## Show live ingestion progress during the run (#544)

The Activity window showed model name, token counts, cost, and timing — but
**only after** the ingestion/lint job completed. During the run, the detail
pane was empty or showed only the source/page display name. The per-turn
`usage_update` notifications were captured in `ACPBackend.SessionUsageState`
but never propagated to the Activity window during the run.

### What changed

**New live-usage pipeline** (`usage_update` → Activity window, during the run):

- `ACPBackend` gains a `liveUsageCallback` (actor-isolated, set via
  `setLiveUsageCallback`). The notification drain loop (in `send()`) invokes
  it right after `captureUsageUpdate`, forwarding the session's current
  `SessionUsage` snapshot (cumulative token totals + context window + cost).
- `AgentLauncher.installLiveUsageCallback(on:)` sets the callback on each
  ACP backend at phase start, enriching each snapshot with the configured
  provider label + the session's current `modelId` (via `currentModelId(for:)`
  actor hop). Installed in `runPhase` + the parallel-executor path.
- `AgentLauncher.run(...)` gains `onLiveUsage` + `providerLabel` params
  (default `nil` — existing call sites unchanged).
- `QueueIngestionProvider` protocol + `AppQueueIngestionProvider` thread
  `onLiveUsage` through `runIngestion`/`runLint`/`runLintPages`.
- `QueueIngestionWorkerFactory`/`QueueIngestionWorker` carry
  `emitLiveUsage`; `QueueEngine.makeEmitLiveUsage()` yields `.liveUsage`.
- `WikiFSApp` wires a `LiveUsageEmitBox` through the factory + engine.

**New `QueueEvent.liveUsage` case** — parallel to `.usage` (which fires once
on completion with final totals). High-volume like `.transcript`/`.progress`:
consumed live by the tracker, NOT logged to the JSONL audit trail.

**`QueueActivityTracker`**:
- New `liveUsage: [QueueItem.ID: SessionUsage]` dictionary, updated on each
  `.liveUsage` event, cleared on terminal state (`.usage` + `removeItem`).
- New `liveUsage(for:)` accessor.
- `itemUsage` (completion) is unchanged.

**Display layer** (`ActivityWindowView`):
- `RowDisplayData` gains `liveUsage`; `buildRowDisplayData` snapshots it.
- Running rows render a live summary line with a per-second `TimelineView`
  for elapsed time: `Sonnet 4 · 12.4K in · 3.2K out · 412 thought · 3m 12s elapsed`.
- The detail header shows the same live line while running; the existing
  on-completion `fullSummary` takes over when the run finishes.
- New `UsageFormatter.liveSummary(usage:)` (model/provider + running tokens,
  no cost/duration — those come from the completion summary + the row timer).
- New `elapsedString(_:now:)` helper.

### What didn't change
- The on-completion usage display (`fullSummary`, `itemUsage`, `DailyUsage`)
  is untouched — it still fires once via `.usage` with the merged run total.
- `AgentEvent` is unchanged (no new case — the live path is a parallel
  callback, not a transcript event).
- The `AgentBackend` protocol is unchanged (live usage is an ACP-specific
  capability; the launcher downcasts to `ACPBackend`).

### Verification
- `make version prompts` ✓
- `swift build` ✓
- Fast test tier: 2573 tests pass ✓
  (`swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|...'`)
