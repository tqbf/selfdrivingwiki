# Phase 2: Persistent quota state (issue #813)

## Problem

The app has `QuotaFallbackCoordinator` (Sources/WikiFSEngine/QuotaFallbackCoordinator.swift) and `ProviderQuotaDetector` that detect provider quota exhaustion (Claude/z.ai rate limits) and mark providers as 'dead' with a revival timestamp. This is per-run only — the state is lost when the app restarts, so the `BackgroundIngestCoordinator` (Phase 1, already merged) re-triggers exhausted providers on every scan cycle.

## Goal

Add lightweight persistence for provider quota state so that exhausted providers stay in cooldown across app restarts. The background ingest coordinator should skip providers that are still in their cooldown period.

## Current architecture

### QuotaFallbackCoordinator (Sources/WikiFSEngine/QuotaFallbackCoordinator.swift)
- `@MainActor final class` — touched only from the launcher's run path
- **State:** `deadUntil: [String: Date]` — providerId → revival time
- **State:** `backends: [String: AgentBackend]` — teardown tracking
- **State:** `plannerProviderId: String?` — which provider actually ran
- **Methods:**
  - `markExhausted(_ providerId: String, resetTime: Date?, kind: QuotaSignal.Kind)` — marks dead
  - `isExhausted(_ providerId: String) -> Bool` — checks if dead, auto-revives if time passed
  - `firstLive(in chain: [AgentProvider]) -> AgentProvider?` — picks first non-dead provider

### ProviderQuotaDetector (Sources/WikiFSEngine/ProviderQuotaDetector.swift)
- Pure, side-effect-free detection of quota errors
- Returns `QuotaSignal?` with `providerId`, `resetTime: Date?`, `kind`
- Two families: `.claude` (text-based) and `.zai` (numeric code-based)

### BackgroundIngestCoordinator (Sources/WikiFS/BackgroundIngestCoordinator.swift)
- Scans all wikis for un-ingested sources
- Currently **does not** check quota state — assumes all providers are live
- Needs integration with `QuotaFallbackCoordinator` to skip dead providers

## Design approach

### Persistence layer: JSON file in app group container

**Chosen approach:** JSON file in the app group container.

**Why:**
- Simple, no schema migration required
- Fast to read/write (tiny dataset: typically <10 providers)
- Easy to inspect/debug
- No SQLite table migration needed (avoid schema churn for lightweight data)
- Follows existing patterns in the codebase (e.g., `wikis.json` registry)

**File location:** `~/Library/Group Containers/<appGroupID>/quota-state.json`

**Schema:**
```json
{
  "version": 1,
  "providers": [
    {
      "providerId": "claude-3-5-sonnet",
      "deadUntil": "2026-07-22T14:30:00Z",
      "kind": "claudeSession"
    }
  ]
}
```

**Why JSON not UserDefaults:**
- Structured data (multiple fields per provider)
- Better for future extensibility (e.g., add `lastSeen`, `failureCount`)
- Debuggable (can open the file and inspect state)

**Why JSON not SQLite:**
- SQLite would require a migration (schema v31 → v32)
- Overkill for this use case
- JSON is already used for `wikis.json` registry in the same container

### Changes to QuotaFallbackCoordinator

**New state:**
```swift
private let quotaStateURL: URL  // Path to quota-state.json
private var quotaState: QuotaState  // In-memory cache
```

**New types:**
```swift
struct QuotaState: Codable {
    var version: Int
    var providers: [ProviderQuotaEntry]
}

struct ProviderQuotaEntry: Codable {
    let providerId: String
    let deadUntil: Date
    let kind: QuotaSignal.Kind
}
```

**New methods:**
- `loadQuotaState()` — called on init, reads JSON and populates `deadUntil`
- `saveQuotaState()` — called whenever quota state changes (markExhausted, isExhausted auto-revival)
- `isExhausted(_ providerId: String) -> Bool` — upgraded to also save on auto-revival

**Flow:**
1. `init(sessionManager:)` → `loadQuotaState()` → populate `deadUntil` from JSON
2. `markExhausted()` → update `deadUntil` → `saveQuotaState()`
3. `isExhausted()` → check dead status → if auto-revival → `saveQuotaState()`

### Integration with BackgroundIngestCoordinator

**Current problem:** `BackgroundIngestCoordinator` does not have a `QuotaFallbackCoordinator` reference.

**Options:**
1. **Add `QuotaFallbackCoordinator` as a dependency** — pass it in `init`
   - Pros: Explicit, testable, follows dependency injection
   - Cons: Requires plumbing through `WikiSession` / `SessionManager` / `WikiFSApp`

2. **Create a shared quota-checking interface** — `QuotaStore` protocol
   - Pros: Decouples from coordinator internals
   - Cons: Over-engineering for a simple check

**Chosen approach:** Option 1 — pass `QuotaFallbackCoordinator` as a dependency.

**Why:**
- Simple and explicit
- No over-abstraction
- Already follows the pattern (`sessionManager`, `queueEngine` are passed in init)
- Testable (can pass a mock coordinator in tests)

**Changes:**
```swift
// BackgroundIngestCoordinator.swift
init(
    sessionManager: SessionManager,
    queueEngine: QueueEngine,
    quotaCoordinator: QuotaFallbackCoordinator  // NEW
) {
    self.sessionManager = sessionManager
    self.queueEngine = queueEngine
    self.quotaCoordinator = quotaCoordinator  // NEW
}

// In scanWiki(session:)
// Check if any provider is exhausted before enqueueing
let liveProviders = providerChain.filter { !quotaCoordinator.isExhausted($0.id) }
if liveProviders.isEmpty {
    DebugLog.ingest("BackgroundIngestCoordinator: skipping source \(source.id.rawValue) - all providers exhausted")
    continue
}
```

**Where to get the provider chain?**
- The `QueueEngine` already has access to `AgentProvider` chains
- Need to add a method to `QueueEngine` or `WikiSession` to get the provider chain for a stage
- For now, we can check each provider individually if we have a list

**Simplified approach:** Check each provider ID in the quota coordinator before enqueuing. The `QueueEngine` knows which providers are enabled.

### Migration strategy

**No schema migration needed** — we're adding a new JSON file, not modifying SQLite.

**Data initialization:**
- On first run, the file doesn't exist → create empty state
- Load on startup → populate `deadUntil` from persisted entries
- Auto-cleanup on load: prune entries where `deadUntil < Date.now` (expired cooldowns)

### Testing

**Unit tests for `QuotaFallbackCoordinator` persistence:**
- Test that `loadQuotaState()` reads from JSON and populates `deadUntil`
- Test that `saveQuotaState()` writes to JSON
- Test that expired entries are pruned on load
- Test that `markExhausted()` triggers a save
- Test that auto-revival in `isExhausted()` triggers a save

**Integration tests for cross-restart persistence:**
- Test: Mark provider dead → save → create new coordinator → load → verify still dead
- Test: Mark provider dead for 5 min → check at 4 min → still dead → check at 6 min → alive

**Integration tests for `BackgroundIngestCoordinator`:**
- Test that exhausted providers are skipped during scanning
- Test that re-enqueued sources are not lost (just deferred to next scan)

## Implementation plan

### Phase 1: Persistence layer (QuotaFallbackCoordinator)
1. Add `QuotaState` and `ProviderQuotaEntry` types
2. Add `quotaStateURL` computed property (resolves app group container path)
3. Implement `loadQuotaState()` — read JSON, prune expired, populate `deadUntil`
4. Implement `saveQuotaState()` — write JSON from `deadUntil` map
5. Update `markExhausted()` to call `saveQuotaState()` after mutation
6. Update `isExhausted()` to call `saveQuotaState()` on auto-revival
7. Add persistence tests

### Phase 2: BackgroundIngestCoordinator integration
1. Add `quotaCoordinator` parameter to `init()`
2. Pass `quotaCoordinator` from `WikiSession` → `SessionManager` → `WikiFSApp`
3. Add quota check in `scanWiki()` before enqueuing
4. Add integration tests

### Phase 3: End-to-end testing
1. Build and run the app
2. Trigger quota exhaustion (simulated)
3. Restart app
4. Verify provider stays dead across restart
5. Wait for cooldown to expire
6. Verify provider auto-revives

## File changes

### New files
- `Tests/WikiFSEngineTests/QuotaFallbackCoordinatorPersistenceTests.swift`

### Modified files
- `Sources/WikiFSEngine/QuotaFallbackCoordinator.swift` — add persistence
- `Sources/WikiFS/BackgroundIngestCoordinator.swift` — add quota checking
- `Sources/WikiFSEngine/WikiSession.swift` — pass quota coordinator
- `Sources/WikiFSEngine/SessionManager.swift` — pass quota coordinator
- `Sources/WikiFS/Window/WikiFSApp.swift` — wire quota coordinator
- `Tests/WikiFSEngineTests/QuotaFallbackCoordinatorTests.swift` — existing tests should still pass

### No changes needed
- `Sources/WikiFSEngine/ProviderQuotaDetector.swift` — read-only, no changes
- `Sources/WikiFSCore/Store/*` — no schema changes
- `Package.swift` — no new dependencies (JSON is Foundation)

## Acceptance criteria

1. **Persistence:** Provider dead state survives app restart
   - Mark provider dead → restart app → verify still in `deadUntil`
2. **Auto-revival:** Revival timestamps are respected
   - Mark dead for 5 min → check at 4 min → still dead
   - Check at 6 min → auto-revived
3. **Integration:** BackgroundIngestCoordinator skips dead providers
   - Source queued for ingest → provider marked dead → scan skips source
   - After cooldown → scan re-enqueues source
4. **No regression:** Existing tests pass
   - All `QuotaFallbackCoordinatorTests` pass
   - All `BackgroundIngestCoordinator` tests pass
5. **Build:** `swift build` and `swift test` pass

## Open questions

1. **Where to get the provider chain in `BackgroundIngestCoordinator`?**
   - The coordinator currently enqueues via `enqueueIngestion(sourceIDs:store:wikiID:queueEngine:)`
   - Need to know which provider(s) to check for exhaustion
   - Option A: `QueueEngine` exposes `enabledProviders` list
   - Option B: Pass a list of provider IDs to check
   - **Decision:** Use `QueueEngine.enabledProviders` (add a getter)

2. **Should we persist `backends` and `plannerProviderId`?**
   - These are per-run state, tied to a specific ingestion run
   - No point persisting them — they don't survive restarts anyway
   - **Decision:** Only persist `deadUntil` map

3. **Error handling for JSON read/write failures?**
   - Read failure: Log with `DebugLog` and start with empty state (fallback)
   - Write failure: Log with `DebugLog` but continue (state is still in-memory)
   - **Decision:** Never crash on IO errors, always log and degrade gracefully

4. **Concurrent access to quota-state.json?**
   - Multiple coordinator instances could write simultaneously (unlikely but possible)
   - **Decision:** Use atomic write (write to temp file, then `move` to final path)

## Next steps

1. Implement Phase 1: Persistence layer in `QuotaFallbackCoordinator`
2. Add persistence tests
3. Verify `swift build` and `swift test` pass
4. Implement Phase 2: `BackgroundIngestCoordinator` integration
5. Add integration tests
6. Verify end-to-end behavior
7. Update PLAN.md with new feature
8. Update PROGRESS.md with implementation notes
9. Push branch and open PR linking #813