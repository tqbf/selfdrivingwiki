# Background Ingest Plan (Phase 1 - Issue #813)

## Overview
Implement a BackgroundIngestCoordinator that continuously scans for un-ingested sources and enqueues them automatically. This enables "continuous sync" mode where newly created or processed sources are ingested without user intervention.

## Components

### 1. BackgroundIngestCoordinator (`Sources/WikiFSEngine/BackgroundIngestCoordinator.swift`)

**Core responsibilities:**
- Periodic scan loop (60 second intervals)
- Detects un-ingested sources: `!store.isSourceIngested(source.id) && store.canIngest(source.id)`
- Enqueues batches via existing `enqueueIngestion()` chokepoint
- Tracks recently failed sources with backoff (skip for N=3 cycles)
- Comprehensive logging via DebugLog

**Key design decisions:**
- `@MainActor @Observable` - integrates with SwiftUI state management
- Cancelation support on deinit or toggle off
- Does NOT implement ingestion logic itself - pure consumer
- Respects queue engine's per-wiki ingestion invariant (no need to check)

**State tracking:**
- `recentlyFailedIDs: Set<PageID>` - sources that failed ingestion recently
- `backoffCount: [PageID: Int]` - tracks how many cycles to skip per source
- Scan cycle logging: start/end, items found, items enqueued, items skipped

**Logging requirements:**
- Scan start: "BackgroundIngestCoordinator: starting scan for wiki \(wikiID)"
- Scan end: "BackgroundIngestCoordinator: scan complete for wiki \(wikiID) - found \(foundCount), enqueued \(enqueuedCount), skipped \(skippedCount)"
- Item enqueue: "BackgroundIngestCoordinator: enqueued \(sourceID) for wiki \(wikiID)"
- Backoff skip: "BackgroundIngestCoordinator: skipping failed source \(sourceID) (backoff cycle \(currentCycle)/\(maxBackoffCycles))"
- Byteless skip: "BackgroundIngestCoordinator: skipping byteless source \(sourceID) (no content to ingest)"

**Implementation notes:**
- Use `Task.sleep(for: .seconds(60))` in the scan loop
- Check `!Task.isCancelled` after sleep to handle immediate cancelation
- Access store via sessionManager.session(for: wikiID) (multi-wiki support)
- Each wiki gets its own scan pass

### 2. OperationsSettingsView Toggle

**Add to `Sources/WikiFS/Settings/OperationsSettingsView.swift`:**
- New `@AppStorage("backgroundIngestEnabled")` boolean toggle
- Toggle label: "Background Ingest"
- Toggle description: "Continuously scan for un-ingested sources and enqueue them automatically"
- Toggle section header: "Continuous Sync"

**Storage:**
- Use `@AppStorage("backgroundIngestEnabled")` for persistence
- Default value: `false` (opt-in feature)

### 3. WikiFSApp Integration

**Add to `Sources/WikiFS/Window/WikiFSApp.swift`:**
- Instantiate `BackgroundIngestCoordinator` in `init()`
- Pass `sessionManager` and `queueEngine` dependencies
- Start coordinator when toggle is `true`, cancel when `false`
- Monitor toggle changes via `.onChange(of: backgroundIngestEnabled)`

**Lifecycle management:**
- Coordinator is an app-scoped @State property (like `queueEngine`, `activityTracker`)
- Toggle changes trigger `start()` or `stop()` methods
- Deinit cancels any running scan task

## Constraints & Invariants

### What NOT to do:
- ❌ Modify `QueueEngine.swift` or `QueueIngestionHelper.swift`
- ❌ Implement ingestion logic in the coordinator
- ❌ Check per-wiki ingestion limits (enforced by queue engine)
- ❌ Use `print()` statements - use `DebugLog`
- ❌ Use bare `try?` to swallow errors

### What MUST be done:
- ✅ Call existing `enqueueIngestion()` for all enqueue operations
- ✅ Respect `canIngest()` predicate (skip byteless sources without markdown)
- ✅ Check `isSourceIngested()` to avoid re-ingesting completed sources
- ✅ Log all operations through `DebugLog` (subsystem: `com.selfdrivingwiki.debug`)
- ✅ Use proper error handling with `do { try ... } catch { DebugLog... }`
- ✅ Support multi-wiki scanning (iterate over all active wikis)
- ✅ Backoff on failures (skip for 3 cycles, then retry)
- ✅ Cancel scan task on deinit or toggle off

## Integration Points

### Dependencies:
- `WikiStoreModel` - access to `isSourceIngested()` and `canIngest()`
- `SessionManager` - resolves per-wiki store instances
- `QueueEngine` - receives enqueue requests
- `QueueIngestionHelper.enqueueIngestion()` - existing chokepoint

### Thread safety:
- `@MainActor` ensures all access to store and queue engine is safe
- Scan loop runs in a `Task` that can be cancelled
- No off-main thread access to store needed (scan is fast, not heavy compute)

## Testing Considerations

While not implementing tests in Phase 1, the design supports:
- Single-wiki background ingest toggle
- Multi-wiki scanning (each wiki independently)
- Backoff on transient failures
- Byteless source filtering
- Queue deduplication (handled by `enqueueIngestion`)

## Future Work (Not in Phase 1)

- Configurable scan interval (currently fixed at 60 seconds)
- Per-wiki enable/disable (currently global toggle)
- Configurable backoff strategy
- Background ingest statistics dashboard
- Manual scan trigger button