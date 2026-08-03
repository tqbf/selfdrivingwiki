---
timestamp: 2026-07-16T032543Z
title: "2026-07-13 — Queue Engine Phase 2: QueueEngine actor"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-13 — Queue Engine Phase 2: QueueEngine actor

## Progress


**Phase 2 is implemented.** The design plan lives at
`docs/design-plans/2026-07-13-queue-engine.md`. This phase adds the
`QueueEngine` actor — the scheduling engine with write-through persistence,
event-driven dispatch, per-provider concurrency limits, per-wiki ingestion
invariant, pause/resume/halt/cancel/retry, and an `AsyncStream<QueueEvent>`
for UI observation. Still no app-layer wiring (that's Phase 4+); the engine
is fully testable with fake workers.

**New types (all in `Sources/WikiFSEngine/`):**
- **`QueueEngine`** (`QueueEngine.swift`) — an `actor` that owns all scheduling.
  Every state change writes through to `QueueStore` before emitting a
  `QueueEvent`. Event-driven dispatch (no polling): `enqueue`, item finish,
  `resume`, `retryItem` all trigger `dispatchScan()`. Worker `Task`s are
  spawned detached so the engine never blocks on a worker.
- **`QueueWorker.swift`** — supporting types:
  - `QueueWorker` protocol — `execute(_:)` runs one item.
  - `QueueWorkerFactory` protocol — resolves a provider ID (capacity check) and
    produces a worker (execution). Split so the engine checks capacity without
    committing a worker.
  - `QueueEvent` enum — `.enqueued`/`.started`/`.completed`/`.failed`/
    `.cancelled`/`.runStateChanged`. `Sendable` for crossing actor boundaries.
  - `QueueSnapshot` struct — point-in-time state for UI bootstrap (active
    items, recent items, run states, provider counts, active ingestion wikis).
  - `QueueEngineConfig` struct — capacity limits: per-provider ingestion limits,
    local extraction limit (default 1), remote extraction limit (default 2).

**Modified (in `Sources/WikiFSCore/`):**
- **`AgentProvidersConfig`** — added `maxConcurrent: [String: Int]` field for
  per-provider ingestion limits. Forward-compatible (old files decode to `[:]`);
  all internal constructor calls carry it over.

**Tests** (`Tests/WikiFSTests/QueueEngineTests.swift`): 16 tests with fake
workers, all pass in 0.77s. Covers:
- Dispatch order (ordering-key / FIFO)
- Per-provider concurrency limit (at max, blocks)
- Different providers run concurrently
- Per-wiki ingestion invariant (at most 1 per wiki)
- Local extraction serialized (limit 1)
- Pause stops new dispatch; resume restarts
- Pause state persists across reopen
- Halt cancels in-flight items (requeue preserves ordering key)
- Failed item records error, frees slot, doesn't block later items
- Retry re-enqueues with attempt + 1
- Enqueue returns immediately (UI never awaits slots)
- Items from multiple wikis in one shared queue
- Crash recovery / rehydration (running → queued on launch)
- Event stream emits enqueued/started/completed
- Snapshot reflects engine state
- Cancel queued item

Also updated `QueueStoreTests.testNoExternalReferencesToQueueStore` to only
scan `Sources/WikiFS/` (the app layer) — `WikiFSEngine` now legitimately
references queue types (Phase 2). The guard now also checks for `QueueEngine`,
`QueueEvent`, `QueueSnapshot`.

**Acceptance criteria covered:**
- AC2.1 (multi-wiki items in one queue) ✓
- AC2.2 (dispatch in ordering-key order) ✓
- AC2.5 (crash recovery rehydration) ✓ (from Phase 1, re-verified for engine)
- AC3.1 (different providers run concurrently) ✓
- AC3.2 (provider at max blocks) ✓
- AC3.3 (at most one ingestion per wiki) ✓
- AC3.4 (local pdf2md serialized) ✓
- AC3.5 (pause/resume persists) ✓
- AC3.6 (halt cancels in-flight) ✓
- AC3.7 (failed item records error, frees slot, retry) ✓
- AC4.1 (enqueue returns immediately) ✓

**Files (2 new + 1 modified + 1 test + 1 test modified):**
- `Sources/WikiFSEngine/QueueEngine.swift` (new)
- `Sources/WikiFSEngine/QueueWorker.swift` (new)
- `Sources/WikiFSCore/AgentProvidersConfig.swift` (modified — `maxConcurrent`)
- `Tests/WikiFSTests/QueueEngineTests.swift` (new, 16 tests)
- `Tests/WikiFSTests/QueueStoreTests.swift` (modified — source-scan scope)

## Verification

Historical verification remains in the progress record above.
