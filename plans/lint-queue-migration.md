# Lint Queue Migration

## Summary

Move the Lint operation (`runLint` + `runLintPages`) from the `GenerationGate`'s `.ingest` lane onto the central `QueueEngine`, as a new `.lint` QueueKind. This completes the queue migration started in Phases 4–5: extraction and ingestion already flow through the queue, but lint was left on the old gate path. After this migration, lint gets persistence (survives relaunch), appears in the menu-bar queue popover, respects pause/halt/cancel/retry, and serializes per-wiki alongside ingestion via the shared write-class invariant.

## Design Decisions

### New `.lint` QueueKind (not folded into `.ingestion`)

Lint is a distinct operation (read-only health-check vs. page-writing ingestion)
with its own payload (page IDs for page-level lint), its own UI surface (LintView tab),
and its own controls. A separate queue kind gives independent pause/resume/halt and
clear separation in the popover. Matches the design doc's "one queue per kind" pattern.

### Shared per-wiki write invariant

Lint and ingestion both write to the wiki (log.md, possibly pages). The queue engine
enforces "at most one write-class agent per wiki at a time" — lint and ingestion
share the same per-wiki slot. This replaces the old per-session `.ingest` gate lane
(limit 1), which enforced the same thing at a different layer. Cross-wiki concurrency
is preserved (each wiki gets its own slot).

### Gate becomes belt-and-suspenders (not removed yet)

The lint provider calls `launcher.run(request: .lint(...))` which still acquires the
gate's `.ingest` lane. The gate is per-session (per-wiki), so it serializes within a
wiki — the same invariant the queue enforces. It's redundant but not harmful.
Removing gate acquisition for queue-managed operations is a future cleanup, not part
of this migration.

### Payload: render state at execution time

`QueueItemPayload` gains an optional `lintPageIDs: [PageID]?`. If present, the worker
runs page-level lint; if nil, whole-wiki lint. The provider renders `WIKI_STATE.md`
and runs `preflightLint` at execution time (same as `AppQueueIngestionProvider`
re-renders state), so enqueued items use current wiki state, not a stale snapshot.

## Implementation

### Phase 1: Core types (WikiFSCore)

- `QueueTypes.swift`: Add `.lint` to `QueueKind`; add `lintPageIDs: [PageID]?` to `QueueItemPayload`
- `QueueEngineConfig`: Add per-wiki lint limit (default 1, same as ingestion)

### Phase 2: Engine (WikiFSEngine)

- `QueueEngine.swift`:
  - Add `.lint` to all queue-iteration arrays: `start()`, `dispatchScan()`, `snapshot()`
  - Extend per-wiki write invariant: `.lint` items check/set the same wiki set as `.ingestion`
    (rename `activeIngestionWikis` → `activeWriterWikis` for clarity)
  - `dispatchScan`: `.lint` capacity check = per-wiki (same as ingestion's per-wiki invariant)
- `QueueLintProvider.swift`: New `QueueLintProvider` Sendable protocol with `runLint(wikiID:onProgress:)`
  and `runLintPages(wikiID:pageIDs:onProgress:)`
- `QueueLintWorker.swift`: `QueueLintWorker` + `QueueLintWorkerFactory`

### Phase 3: App bridge (WikiFS)

- `AppQueueLintProvider.swift`: `@MainActor` class, calls `AgentOperationRunner.runLint`/
  `runLintPages` (reuses existing agent-launch path, which goes through `launcher.run`)
- `WikiFSApp.swift`: Wire lint provider + factory into `CompositeWorkerFactory`

### Phase 4: Call-site migration

- `LintView.swift`: Enqueue `.lint` item, show queue status (item state from tracker)
- `PagesContainerView.swift`: Enqueue `.lint` item with page IDs
- `PageDetailView.swift`: Enqueue `.lint` item with single page ID

### Phase 5: Activity tracker + popover

- `QueueActivityTracker`: Track `.lint` items (started/completed/failed events)
- `QueuePopoverView`: Show `.lint` items in the grouped list

### Phase 6: Tests + verification

- QueueEngine tests: lint dispatch, per-wiki serialization with ingestion, pause/halt
- Build + fast test tier
- Update PROGRESS.md
