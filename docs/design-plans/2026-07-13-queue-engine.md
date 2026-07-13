# Queue Engine Design

## Summary

This design replaces WikiFS's per-wiki, in-memory extraction and ingestion lanes with a single app-wide queue engine. Today, work such as extracting text from a PDF or ingesting a source into a wiki is tracked per `WikiSession` and disappears when its window closes; this design moves that state into a `QueueEngine` actor backed by a new central SQLite database, so items survive relaunch, can be scheduled across wikis with per-provider concurrency limits, and keep running even when no window is open. The engine lives in the headless `WikiFSCore`/`WikiFSEngine` layers with no AppKit/SwiftUI dependency, and the app talks to it only through an async actor interface and an event stream — a boundary chosen so the engine could later be hosted outside the GUI process (e.g. via XPC or as a service) without a rewrite.

On the UI side, the app becomes a menu-bar-first application: it behaves as a normal dock app while windows are open, but drops to an accessory (menu-bar-only) process once the last window closes, with a status-item popover replacing the right-hand `AgentActivitySidebar` as the place to see and control queued work across all wikis (pause/resume/halt, retry, per-item progress). The rollout is staged — building the persistence layer and scheduler first, then migrating extraction and ingestion onto it one at a time, and only then wiring in the menu-bar UI and removing the old sidebar — so that each phase is independently testable and the app never regresses mid-migration.

## Definition of Done

1. The app behaves as a normal dock app while windows are open, and drops to a **menu-bar-only accessory** when the last window closes, with queued work continuing in the background (dynamic `NSApplication.ActivationPolicy`, not hardcoded `LSUIElement`).
2. **One app-wide extraction queue and one ingestion queue** fully replace the per-`WikiSession` ingest lanes in this milestone — all extraction/ingestion flows through the central queues; items carry their wiki identity.
3. Queue state persists in a **new central app-level SQLite database** (App Group container), built on the app's existing SQLite layer and its concurrency discipline — no new dependency.
4. **Workers with per-provider concurrency limits** (Claude, Hermes, OpenCode, custom) pull items from the queues; two providers can work simultaneously. Manual **pause / resume / halt** controls exist per queue.
5. The **status-item popover is the queue UI** (items across all wikis, progress, controls). The right sidebar (`AgentActivitySidebar`) is removed; interactive chat-turn activity stays inline in the wiki window.

### Architectural constraint: headless isolation

Queue store, scheduler, and workers live in `WikiFSCore`/`WikiFSEngine` with zero AppKit/SwiftUI dependencies; UI talks to the engine through a narrow async interface that could later be fronted by XPC or HTTP. Nothing in the engine may assume a GUI process. This keeps future doors open (wikid-hosted execution, embedded MCP server, OpenAPI service) without building any of them now.

### Out of scope (deferred)

- Queue reordering UI (schema must use explicit ordering keys so this is later UI work, not a migration)
- Batch multi-enqueue UX
- Automatic quota/resource reactions (provider errors, thermal, battery, scheduled windows) — manual controls only
- Moving queue execution into `wikid`; MCP/OpenAPI serving

## Acceptance Criteria

### queue-engine.AC1: Menu-bar background mode
- **queue-engine.AC1.1 Success:** Closing the last window switches the app to accessory mode (no dock icon) and it keeps running.
- **queue-engine.AC1.2 Success:** Queued work continues executing after the last window closes.
- **queue-engine.AC1.3 Success:** Opening a window (via popover or app reopen) restores the dock icon and normal activation.
- **queue-engine.AC1.4 Failure:** Quitting with active work prompts for confirmation; confirming cancels in-flight items back to `queued` before exit.

### queue-engine.AC2: Central queues with SQLite persistence
- **queue-engine.AC2.1 Success:** Enqueued items from multiple wikis appear in one shared queue per kind, tagged with wiki identity.
- **queue-engine.AC2.2 Success:** Items dispatch in ordering-key (FIFO) order.
- **queue-engine.AC2.3 Success:** A PDF source enqueues an extraction item whose completion enqueues the linked ingestion item.
- **queue-engine.AC2.4 Success:** Every state change is durably written; relaunch restores queued/paused items exactly.
- **queue-engine.AC2.5 Success:** Rows found `running` at launch reset to `queued` with attempt count intact.
- **queue-engine.AC2.6 Edge:** Completed/failed history is pruned beyond the bound (~200 per queue).
- **queue-engine.AC2.7 Success:** No extraction path remains that bypasses the queue (extraction slot machinery removed).
- **queue-engine.AC2.8 Success:** No ingestion path remains that bypasses the queue (`GenerationGate` ingest lane removed; interactive lane intact).

### queue-engine.AC3: Workers, limits, and controls
- **queue-engine.AC3.1 Success:** Items assigned to different providers run concurrently.
- **queue-engine.AC3.2 Success:** A provider at `maxConcurrent` doesn't start further items until a slot frees.
- **queue-engine.AC3.3 Success:** At most one ingestion runs per wiki at any time.
- **queue-engine.AC3.4 Success:** Local pdf2md extraction stays serialized (limit 1); remote extraction respects its configured limit.
- **queue-engine.AC3.5 Success:** Pause stops new dispatch; in-flight items complete. Resume restarts dispatch. Pause state survives relaunch.
- **queue-engine.AC3.6 Success:** Halt cancels in-flight items; they return to `queued` at their prior position.
- **queue-engine.AC3.7 Failure:** A failed item records its error, frees its slot, and doesn't block later items; Retry re-enqueues it with attempt + 1.

### queue-engine.AC4: Execution correctness
- **queue-engine.AC4.1 Success:** Enqueue returns immediately — UI actions never await slots.
- **queue-engine.AC4.2 Failure:** Enqueue rejects items referencing a missing wiki or unconfigured provider.
- **queue-engine.AC4.3 Success:** A running ingest survives its wiki's window closing (conditional session release).
- **queue-engine.AC4.4 Success:** `isIngestInProgress` chat-blocking, workspace auto-merge, and `WikiEventBus` propagation behave as before.
- **queue-engine.AC4.5 Success:** Chat turns still run through the interactive lane, unaffected by queue state.

### queue-engine.AC5: Queue UI and sidebar removal
- **queue-engine.AC5.1 Success:** Popover lists items across all wikis with state, provider, wiki, progress/error.
- **queue-engine.AC5.2 Success:** Per-queue pause/resume/halt and per-row cancel/retry work from the popover.
- **queue-engine.AC5.3 Success:** Status-item icon reflects idle/working/paused/attention states.
- **queue-engine.AC5.4 Success:** Clicking a row opens/focuses that wiki's window.
- **queue-engine.AC5.5 Success:** `AgentActivitySidebar` is gone; source rows still show Extracting…/Ingesting… from queue events.
- **queue-engine.AC5.6 Success:** Chat transcript and stop control work inline in the wiki window.

### queue-engine.AC6: Machine-readable logging
- **queue-engine.AC6.1 Success:** Every queue event is appended as a valid JSON line with item, wiki, and provider IDs and timestamps.
- **queue-engine.AC6.2 Success:** Log files rotate daily under `Logs/queue/` with bounded retention.
- **queue-engine.AC6.3 Success:** Completed/failed records include duration and (where applicable) the run-log path.

## Glossary

- **`WikiSession`**: The app's in-memory representation of an open wiki, holding its store connection and active work; historically owned per-wiki ingest lanes that this design centralizes.
- **`WikiFSCore` / `WikiFSEngine` / `WikiFS`**: The app's module layering — `WikiFSCore` holds pure data and persistence with no UI dependency, `WikiFSEngine` hosts the running engine/business logic, and `WikiFS` is the SwiftUI/AppKit app shell. The "headless isolation" constraint keeps the first two free of GUI frameworks.
- **`GenerationGate`**: An existing FIFO-waiter component that gates interactive chat-turn and ingest concurrency; this design generalizes its shape into the new queue engine and shrinks the original to interactive-only use.
- **`SessionManager`**: Existing app-wide component that creates/caches `WikiSession`s and can resolve a session for a wiki without a window being open.
- **`AgentOperationRunner`**: Existing entry point that UI actions (ingest button, drag-drop) call to kick off agent work; this design changes it to enqueue instead of directly running work.
- **`AgentLauncher`**: Existing component that launches and tracks provider agent processes for chat/extraction; its extraction slot-limiting machinery is retired in favor of the queue engine's capacity limits.
- **`ExtractionCoordinator`**: Existing component that performs PDF-to-markdown extraction; the new extraction `QueueWorker` calls into it rather than replacing it.
- **App Group container**: An Apple sandboxing mechanism that lets an app (and its extensions/helpers) share a private file location; used here to store the new central `queue.sqlite` database and rotated log files so they persist independent of any single window process.
- **`NSApplication.ActivationPolicy`**: An AppKit setting controlling whether a Mac app shows a Dock icon and behaves like a normal app (`.regular`) or runs hidden with no Dock presence (`.accessory`). This design switches it dynamically at runtime rather than fixing it via the `LSUIElement` Info.plist key.
- **`LSUIElement`**: An Info.plist flag that permanently marks an app as a background/menu-bar-only agent at launch; rejected here because the app needs to toggle between normal and accessory behavior depending on whether windows are open.
- **`NSStatusItem` / `NSPopover`**: AppKit classes for putting a persistent icon in the macOS menu bar (`NSStatusItem`) and showing a floating panel of content when it's clicked (`NSPopover`); together they form the new queue UI.
- **Actor (Swift)**: A Swift concurrency type that serializes access to its internal state, preventing data races without manual locking; `QueueEngine` is implemented as an actor to safely own scheduling state accessed from multiple tasks.
- **`AsyncStream`**: A Swift concurrency type for producing a sequence of asynchronously-emitted values that can be iterated with `for await`; used here to broadcast `QueueEvent`s from the engine to UI observers.
- **Write-through persistence**: A caching/state pattern where every change to an in-memory representation is immediately and synchronously written to durable storage before being considered committed, so the in-memory state and the database never diverge.
- **WAL (Write-Ahead Logging)**: A SQLite journaling mode that allows concurrent readers and a single writer by logging changes before applying them, improving concurrency over the default rollback journal.
- **Method-atomic lock**: This codebase's SQLite discipline where each store method acquires a single recursive lock for its full duration (rather than leaking connection/transaction state across calls), avoiding stale reads and `SQLITE_BUSY` errors.
- **Statement cache**: A pattern of reusing prepared SQL statements (keyed by SQL text) across calls instead of re-preparing them each time, for performance.
- **Versioned/idempotent migrations**: A schema-evolution pattern where each database change is a numbered, safely-rerunnable migration step, so the schema can be brought up to date regardless of the database's starting version.
- **Gap-based ordering key**: An integer ordering scheme (e.g., 1000, 2000, 3000, ...) with large gaps between existing values, so a new item can be inserted between any two neighbors without renumbering the whole list — used here to allow future drag-to-reorder without a schema migration.
- **ULID**: A Universally Unique Lexicographically sortable Identifier — like a UUID but sortable by generation time — used here as the primary key for queue items.
- **JSONL (JSON Lines)**: A log/file format where each line is an independent, valid JSON object, making the file both streamable and greppable; used for the queue's machine-readable audit log.
- **`WikiEventBus`**: Existing app-wide event propagation mechanism that notifies interested parties (e.g., UI) of wiki state changes; this design preserves its existing behavior unchanged.
- **`isIngestInProgress`**: An existing store-level flag used to block chat interactions while an ingest is running on a wiki; preserved unchanged by this design.
- **Workspace auto-merge**: Existing behavior where a wiki's isolated ingest workspace is automatically merged back into the main store on completion; preserved unchanged by this design.
- **XPC**: Apple's inter-process communication mechanism, used to let separate processes on the same Mac call into each other's APIs; mentioned as a future option for hosting the engine outside the GUI process.
- **`wikid`**: A hypothetical/future headless daemon process for hosting the engine outside the GUI app, referenced as an out-of-scope future direction this design's architecture keeps open.
- **MCP (Model Context Protocol)**: A protocol for exposing tools/data to AI agents; mentioned as a future integration surface the headless engine design leaves room for.
- **OpenAPI**: A standard specification format for describing HTTP APIs; mentioned as a future way the engine's surface could be exposed as a network service.

## Omitted Terms
FIFO, Codable, dock icon, menu bar, subprocess, CRUD, JSON, SQLite (general concept), retry, concurrency limit, provider (Claude/Hermes/OpenCode as agent providers), state machine

## Architecture

**Selected approach: actor scheduler with write-through persistence.** A single `QueueEngine` actor owns all scheduling in memory (generalizing the proven `GenerationGate` shape); every state change writes through to a new central SQLite database before it is observable. On launch the database rehydrates the engine. Multi-process claim machinery (leases, heartbeats) is deliberately omitted — the app is single-process — but the schema's state machine is compatible with adding it if the engine later moves into `wikid`.

### Components

**`WikiFSCore` (new files — pure data + persistence, no engine logic):**
- `QueueItem` — Codable value type: id (ULID), queue kind (`.extraction` / `.ingestion`), wiki ID, payload (source/page IDs, options, chained-item link), state, ordering key, provider ID, attempt count, timestamps, failure message.
- `QueueStore` — the central `queue.sqlite` database in the App Group container, built with the same statement-cache / WAL / method-atomic-lock / versioned-migration patterns as `SQLiteWikiStore`. CRUD plus state transitions; no scheduling opinions.

**`WikiFSEngine` (new files — the running engine):**
- `QueueEngine` (actor) — single owner of scheduling. Holds in-memory queue mirrors, per-provider slot counts, per-queue run state. Every mutation writes through to `QueueStore`. Surface:

```swift
actor QueueEngine {
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID
    func pause(_ queue: QueueKind) async
    func resume(_ queue: QueueKind) async
    func halt(_ queue: QueueKind) async           // pause + cancel in-flight; items return to queued
    func cancelItem(_ id: QueueItem.ID) async
    func retryItem(_ id: QueueItem.ID) async      // failed → queued, attempt + 1
    func snapshot() async -> QueueSnapshot        // full state for UI bootstrap
    var events: AsyncStream<QueueEvent> { get }   // enqueued/started/stageChanged/progress/completed/failed/cancelled/pausedResumed
}
```

- `QueueWorker` — a `Task` spawned by the engine per claimed item. Extraction items call `ExtractionCoordinator`; ingestion items run the existing planner→executor→finalizer pipeline through a `SessionManager`-provided `WikiSession`.
- `QueueEventLog` — JSONL append-only log of every `QueueEvent` (daily files under `Logs/queue/` in the App Group container, bounded retention).

**`WikiFS` (app — UI only):**
- Status-item controller (`NSStatusItem` + `NSPopover`, AppKit) and a SwiftUI popover view consuming a `@MainActor` observable view-model fed by `QueueEngine.events`.
- `AppDelegate` gains dynamic activation policy switching.

Nothing in `WikiFSCore`/`WikiFSEngine` imports AppKit or SwiftUI (headless constraint). The engine's surface is async actor methods plus a serializable event stream — front-able by XPC or HTTP later.

### Data model

One table for both queues (queue kind is a column; unified popover list, per-queue pause state trivial):

```sql
CREATE TABLE queue_items (
  id            TEXT PRIMARY KEY,      -- ULID
  queue         TEXT NOT NULL,         -- 'extraction' | 'ingestion'
  wiki_id       TEXT NOT NULL,
  payload       TEXT NOT NULL,         -- JSON (Codable): source IDs, options, stage routing, chained-item link
  state         TEXT NOT NULL,         -- 'queued'|'running'|'completed'|'failed'|'cancelled'
  ordering_key  INTEGER NOT NULL,      -- gap-based (1000, 2000, ...) for future reordering
  provider_id   TEXT,                  -- resolved at claim time
  attempt       INTEGER NOT NULL DEFAULT 0,
  error         TEXT,
  created_at    INTEGER NOT NULL,
  started_at    INTEGER,
  finished_at   INTEGER
);
CREATE INDEX idx_queue_items_active ON queue_items(queue, state, ordering_key);
```

Plus a `queue_state` table holding each queue's run mode (`running` / `paused`) so pause survives relaunch.

- **Gap-based ordering keys** (new items get `max + 1000`): FIFO now; reordering later assigns a key between neighbors — no migration.
- **Rehydration:** on launch, non-terminal rows load into the engine; rows still `running` (crash artifacts) reset to `queued` with attempt count intact.
- **History:** completed/failed rows kept bounded (~200 per queue) for the popover's recent-results view, pruned beyond.

### Scheduling and capacity

Event-driven dispatch (no polling): any change that could unblock work — enqueue, item finish, resume, limit edit — triggers a scan of each running queue in ordering-key order, starting every satisfiable item.

- **Extraction capacity:** local pdf2md serialized (limit 1, a local subprocess); remote backends (Claude, Docling Serve) get a configurable small limit.
- **Ingestion capacity:** per-provider `maxConcurrent` (default 1), stored in `AgentProvidersConfig` alongside existing per-stage routing. Items on different providers run simultaneously.
- **Per-wiki invariant:** at most one ingestion runs per wiki at a time (ingest agents write to the wiki store); cross-wiki concurrency is the goal.

**Pause** stops dispatch, in-flight items finish. **Halt** additionally cancels in-flight worker `Task`s (terminating agent processes as the Stop button does today); halted items return to `queued` at their old position. **Failed** items stay visible with their error; Retry re-enqueues (attempt + 1). No automatic retries this milestone.

### Execution flow

1. UI action (Ingest button, drag-drop, multi-select) calls `AgentOperationRunner`, which now enqueues and returns immediately.
2. PDF sources become **two chained items**: an extraction item whose completion enqueues the linked ingestion item. Non-PDF sources enqueue straight to ingestion.
3. Workers resolve wikis via `SessionManager.session(for:)` (already works without a window; sessions are cached app-wide).
4. `GenerationGate`'s ingest lane is **deleted**; the engine's provider slots + per-wiki invariant replace it. The interactive lane stays — chat turns remain per-session, outside the queue.
5. Unchanged: `store.isIngestInProgress` chat-blocking, workspace isolation + auto-merge, `WikiEventBus` propagation.
6. Session release (`RootScene.onDisappear`) becomes conditional: sessions with queued/running work are retained by the engine and released when their work drains.

## Existing Patterns

Investigation (Sources/WikiFSCore, Sources/WikiFSEngine, Sources/WikiFS) found these patterns, which this design follows:

- **SQLite discipline** (`WikiFSCore/SQLiteWikiStore.swift`): statement cache keyed by SQL text, `PRAGMA journal_mode=WAL` + `busy_timeout=5000`, method-atomic `NSRecursiveLock`, versioned idempotent migrations. `QueueStore` replicates this shape for `queue.sqlite`. The repo's sqlite-concurrency discipline (method-atomic store, no connection state across call boundaries) applies.
- **App-level config in App Group container** (`WikiFSCore/AgentProvidersConfig.swift`, `ExtractionConfig.swift`): per-provider concurrency limits extend `AgentProvidersConfig`, matching the existing per-stage routing storage.
- **Lane-based gating** (`WikiFSEngine/GenerationGate.swift`): the engine generalizes this FIFO-waiter shape to persistent, app-wide queues. The gate itself shrinks to interactive-only.
- **Per-run JSONL logs** (`run.jsonl` + `run.stderr.log` in temp): `QueueEventLog` follows the JSONL convention; queue events reference run-log paths for drill-down.
- **Event streaming to UI**: today UI binds `@Observable AgentLauncher` properties. This design diverges for queue state — an `AsyncStream<QueueEvent>` consumed by a view-model — because the engine must not depend on Observation-driven UI (headless constraint). Divergence is deliberate and localized to queue state; chat activity keeps the existing launcher-property pattern.

New patterns introduced: persistent job queue (no precedent in codebase; schema follows established external practice — state-machine column, gap-based ordering, startup recovery), and dynamic activation policy via `AppDelegate` (`applicationShouldTerminateAfterLastWindowClosed` returning false + `.accessory`; ScenePhase is unreliable for last-window-close on macOS).

## Implementation Phases

<!-- START_PHASE_1 -->
### Phase 1: Queue data model and store
**Goal:** Persistent queue state with no behavior change to the app.

**Components:**
- `QueueItem`, `QueueKind`, `QueueItemState`, `QueueItemRequest` value types in `Sources/WikiFSCore/`
- `QueueStore` in `Sources/WikiFSCore/QueueStore.swift` — `queue.sqlite` with `queue_items` + `queue_state` tables, migrations, CRUD, state transitions, ordering-key assignment, bounded history pruning, crash-recovery reset (`running` → `queued`)

**Dependencies:** None.

**Covers:** queue-engine.AC2.4, AC2.5, AC2.6.

**Done when:** Store tests pass — schema bootstrap, state transitions, gap-based ordering, rehydration query, pruning; app builds with no behavior change.
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: QueueEngine actor
**Goal:** Scheduling engine, fully testable with fake workers.

**Components:**
- `QueueEngine` actor in `Sources/WikiFSEngine/QueueEngine.swift` — enqueue, dispatch scan, per-provider slots, per-wiki ingestion invariant, extraction-backend limits, pause/resume/halt/cancel/retry, write-through to `QueueStore`, launch rehydration, `AsyncStream<QueueEvent>`
- `QueueEvent`, `QueueSnapshot` types in `Sources/WikiFSEngine/`
- Worker abstraction (protocol) so tests inject fake workers
- Per-provider `maxConcurrent` added to `AgentProvidersConfig` (`Sources/WikiFSCore/AgentProvidersConfig.swift`)

**Dependencies:** Phase 1.

**Covers:** queue-engine.AC2.1, AC2.2, AC2.3, AC3.1–AC3.7.

**Done when:** Engine tests pass with fake workers — dispatch order, provider limits, per-wiki invariant, pause/halt semantics, chained-item completion, event stream contents, rehydration behavior.
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: Machine-readable event log
**Goal:** JSONL audit trail of all queue activity.

**Components:**
- `QueueEventLog` in `Sources/WikiFSEngine/QueueEventLog.swift` — subscribes to the engine's event stream; daily-rotated JSONL files under `Logs/queue/` in the App Group container; bounded retention; every record carries wiki ID, provider ID, item ID, and run-log path when available

**Dependencies:** Phase 2.

**Covers:** queue-engine.AC6.1, AC6.2, AC6.3.

**Done when:** Log tests pass — records are valid JSON lines matching emitted events, rotation and retention behave; log written during engine tests.
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: Extraction through the queue
**Goal:** All PDF extraction flows through the central extraction queue.

**Components:**
- Extraction `QueueWorker` in `Sources/WikiFSEngine/` calling `ExtractionCoordinator` (`Sources/WikiFSCore/ExtractionCoordinator.swift`)
- `AgentOperationRunner` (`Sources/WikiFSEngine/AgentOperationRunner.swift`) extraction paths become enqueues; standalone "Extract Markdown" (`Sources/WikiFS/SourceDetailView.swift`) enqueues too
- PDF→ingestion chaining: extraction completion enqueues the linked ingestion item
- Retire `AgentLauncher` extraction slot machinery (`awaitExtractionSlot`/`releaseExtractionSlot`/`extractionWaiters` in `Sources/WikiFSEngine/AgentLauncher.swift`); local-pdf2md limit-1 enforced by engine capacity
- Source row status ("Extracting…") derives from queue events instead of `launcher.extractingSourceIDs` (`Sources/WikiFS/SourcesListView.swift`, `SourcesContainerView.swift`)

**Dependencies:** Phases 2, 3.

**Covers:** queue-engine.AC2.7, AC4.1, AC4.2.

**Done when:** Extraction integration tests pass; manual verification — dropping PDFs on two wikis queues centrally, pdf2md stays serialized, chained ingestion item appears on completion.
<!-- END_PHASE_4 -->

<!-- START_PHASE_5 -->
### Phase 5: Ingestion through the queue
**Goal:** All ingestion flows through the central queue; per-wiki ingest lanes retired.

**Components:**
- Ingestion `QueueWorker` running planner→executor→finalizer via `SessionManager`-provided sessions (`Sources/WikiFSEngine/SessionManager.swift`), preserving `store.isIngestInProgress`, workspace auto-merge, `WikiEventBus` behavior
- Delete ingest lane from `GenerationGate` (`Sources/WikiFSEngine/GenerationGate.swift`); interactive lane remains
- All ingest call sites enqueue: `ContentView.swift:351-365`, `SourceDetailView.swift:1014`, `SourcesContainerView.swift` multi-ingest, drag-drop path in `ContentView.swift:173-174`
- Conditional session release in `RootScene.onDisappear` (`Sources/WikiFS/RootScene.swift`): engine retains sessions with pending work
- "Ingesting…" row status derives from queue events

**Dependencies:** Phase 4.

**Covers:** queue-engine.AC2.8, AC4.3, AC4.4, AC4.5.

**Done when:** Ingestion integration tests pass; manual verification — two wikis ingest concurrently on different providers, one-per-wiki enforced, closing the window doesn't kill a running ingest, chat still works during another wiki's ingest.
<!-- END_PHASE_5 -->

<!-- START_PHASE_6 -->
### Phase 6: Menu bar presence and background mode
**Goal:** Status item, popover queue UI, dynamic activation policy.

**Components:**
- Status-item controller (AppKit, `NSStatusItem` + `NSPopover`) in `Sources/WikiFS/` with state-reflecting icon (idle/working/paused/attention)
- SwiftUI popover view + `@MainActor` view-model consuming `QueueEngine.events` and `snapshot()`: unified item list grouped by queue, per-row cancel/retry, per-queue pause/resume/halt, running-item stage line, row click opens/focuses the wiki window, Open-wiki and Quit affordances, quit-confirm when work is active
- `AppDelegate` (`Sources/WikiFS/WikiFSApp.swift`): `applicationShouldTerminateAfterLastWindowClosed` → false + `.accessory`; back to `.regular` on window open/reopen

**Dependencies:** Phase 5 (real queue traffic to display).

**Covers:** queue-engine.AC1.1–AC1.4, AC5.1–AC5.4.

**Done when:** View-model unit tests pass; manual verification — close last window: dock icon disappears, work continues, popover controls function; reopening restores dock icon.
<!-- END_PHASE_6 -->

<!-- START_PHASE_7 -->
### Phase 7: Sidebar removal
**Goal:** Right sidebar deleted; remaining duties relocated.

**Components:**
- Delete `Sources/WikiFS/AgentActivitySidebar.swift` and its `ContentView.swift` wiring (detail column, auto-expand `onChange` handlers)
- Stop control for interactive chat runs moves into the chat pane (`Sources/WikiFS/ChatView.swift`, which already renders `launcher.events` inline)
- Remove now-unused `AgentLauncher` extraction-display properties (`extractionLog`, `extractionPID` UI surface) or reroute to queue events

**Dependencies:** Phases 4–6 (sidebar's duties must have new homes first).

**Covers:** queue-engine.AC5.5, AC5.6.

**Done when:** App builds with sidebar gone; manual verification — chat transcript and stop work in-window; extraction/ingestion status visible only via popover and source rows; no dead UI.
<!-- END_PHASE_7 -->

## Additional Considerations

**Error handling:** Worker failures are contained per item — state → `failed`, error recorded in DB and JSONL, provider slot freed, dispatch continues. Engine-level failures (queue DB unwritable) surface as the status item's attention state. Enqueue validates upfront (wiki exists, provider configured) so doomed items never enter the queue.

**Quit semantics:** Quit from the popover (or Cmd-Q) with active work prompts to confirm; on confirm, in-flight items are cancelled and return to `queued` (same path as halt), so relaunch resumes cleanly.

**Future extensibility (doors held open, not built):** the engine's async-actor surface + serializable events permit XPC/HTTP fronting (wikid hosting, MCP server, OpenAPI service); gap-based ordering keys permit drag-to-reorder; the schema's state machine permits lease/heartbeat columns if the queue ever becomes multi-process.
