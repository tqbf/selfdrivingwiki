---
timestamp: 2026-07-16T032543Z
title: "2026-07-13 — Queue Engine Phase 1: Queue data model and store"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-13 — Queue Engine Phase 1: Queue data model and store

## Progress


**Phase 1 is implemented.** The design plan lives at
`docs/design-plans/2026-07-13-queue-engine.md`. This phase adds the persistent
`QueueStore` and its value types to `WikiFSCore` with **no behavior change** —
nothing in `WikiFSEngine` or `WikiFS` references it yet. It is the dependency-
free foundation for the `QueueEngine` actor (Phase 2).

**New types (all in `Sources/WikiFSCore/`):**
- **`QueueStore`** (`QueueStore.swift`) — persistent, durable store for the
  extraction/ingestion work queue. Owns one serial SQLite connection
  (`queue.sqlite`) with the same concurrency discipline as `SQLiteWikiStore`:
  method-atomic `NSRecursiveLock`, statement cache, WAL + busy_timeout, versioned
  idempotent migrations (`PRAGMA user_version`), `withTransaction` savepoint
  nesting (never raw `BEGIN`), `#if DEBUG assertNoBusyStatements()` guard, and
  checkpoint-and-close deinit. No `ResourceChangeEvent` emission (not a
  `WikiStore`).
- **`QueueTypes.swift`** — `QueueKind` (extraction/ingestion), `QueueItemState`
  (queued/running/completed/failed/cancelled), `QueueRunState` (running/paused),
  `QueueItemPayload` (JSON-encoded `sourceIDs` + `stageRouting` + `chainedItemID`),
  `QueueItem` (the durable row, `Codable + Sendable + Identifiable`),
  `QueueItemRequest` (caller-facing enqueue request).
- **`QueueStoreError`** — dedicated error enum (`.open`, `.sqlite(code:message:)`,
  `.notFound(QueueItem.ID)`, `.invalidStateTransition(from:to:)`). Does NOT reuse
  `WikiStoreError` (different `notFound` semantics). `WikiStoreError.sqlite`
  from `SQLiteStatement` is caught and rewrapped via a private `rewrap` helper.

**API surface:**
- `enqueue(_:)` → `QueueItem` (ULID ID, next ordering key = max + 1000)
- `getItem(_:)` → `QueueItem?`
- State transitions: `markRunning`, `markCompleted`, `markFailed`,
  `markCancelled`, `requeue`, `retryItem` (each guarded by a state-transition
  table; invalid transitions throw)
- Queries: `loadActive(for:)` (non-terminal, by ordering_key), `loadRecent(limit:)`
  (terminal, newest-first)
- Crash recovery: `resetRunningToQueued()` → `Int` (resets `.running` → `.queued`,
  attempt preserved)
- Queue run state: `queueRunState(for:)`, `setQueueRunState(_:_:)` (persisted)
- Maintenance: `pruneHistory(maxPerQueue:)` (keeps newest 200 terminal per queue)

**One method added to `DatabaseLocation`:**
- `queueDatabaseURL()` — returns `…/<appGroup>/queue.sqlite`

**Tests** (`Tests/WikiFSTests/QueueStoreTests.swift`): 20 tests, all pass in
0.14s. Covers durability (enqueue/state/run-state across reopen), crash recovery
(running→queued, attempt intact), pruning (250 completed → ≤200, queued
untouched), headless source-scan (no AppKit/SwiftUI imports), no-external-
references source-scan (WikiFSEngine/WikiFS don't reference queue types), ordering
key assignment, all state transitions + invalid-transition throws, retry (new
ordering key), requeue (preserves ordering key), loadActive/loadRecent filtering,
and resetRunningToQueued count. Not tagged `.integration` — fast enough for the
CI fast tier.

**Acceptance criteria met:**
- AC.1 (durability) ✓ — 3 reopen tests
- AC.2 (crash recovery) ✓ — `testRunningItemsResetToQueuedOnLaunch`
- AC.3 (pruning) ✓ — `testHistoryPruningBeyondBound`
- AC.4 (no behavior change) ✓ — `testNoExternalReferencesToQueueStore` + clean build
- AC.5 (headless isolation) ✓ — `testQueueStoreFilesAreHeadless` (source-scan)

**Implementation review:** Dispatched a `general-purpose` subagent to review
against sqlite-concurrency discipline, SQLiteWikiStore pattern fidelity, headless
imports, Swift Testing conventions, and Sendable correctness. No CRITICAL issues.
Two MEDIUM findings fixed:
1. `WikiStoreError` was leaking through `SQLiteStatement` calls — fixed via a
   `rewrap` helper that catches and rewraps to `QueueStoreError.sqlite`.
2. `markRunning`/`retryItem` left stale `finished_at` on non-terminal items —
   fixed by clearing `finished_at = NULL` (and `error = NULL` for `markRunning`)
   in both transitions. Also added `migrate(from:)` stub (LOW-1) for future-
   proofing the migration ladder.

**Files (4 new + 1 modified + 1 test):**
- `Sources/WikiFSCore/QueueTypes.swift` (new)
- `Sources/WikiFSCore/QueueStore.swift` (new)
- `Sources/WikiFSCore/DatabaseLocation.swift` (modified — added `queueDatabaseURL()`)
- `Tests/WikiFSTests/QueueStoreTests.swift` (new)
- `PLAN.md` (doc index updated)
**Phase 7 — sidebar removal:** Deleted `AgentActivitySidebar`, `AgentRunBanner`,
and `PdfExtractionView` — their duties are now served by the menu-bar popover
(queue state + controls), the `QueueActivityTracker` (source row status), and
`ChatView`'s inline stop control. `LintView` now shows the agent transcript
inline instead of in a sidebar. The transcript toggle toolbar button and
`isTranscriptExpanded` state are removed from `ContentView`.

## Verification

Historical verification remains in the progress record above.
