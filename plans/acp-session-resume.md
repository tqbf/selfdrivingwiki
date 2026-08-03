# Plan: ACP Session Resume for Interrupted Ingestions (#813 Phase 3)

## Summary

Persist the ACP session ID in the queue item payload so that when an ingestion
is interrupted (crash/force-quit), the agent can resume the session instead of
restarting from scratch. All required infrastructure exists — `ACPBackend.resume()`
is implemented, the queue payload survives crash recovery.

## Research findings (validated)

- `ACPBackend.resume(sessionID:profile:)` exists at `ACPBackend.swift:1081-1173`
  - Tries `client.resumeSession()` (fast) then `client.loadSession()` (slow)
  - Returns `nil` if resume not supported — caller falls back to fresh start
- `ACPBackend.currentResumableSessionId()` exposes the session ID
- `resetRunningToQueued()` preserves the `payload` JSON column (only modifies
  `state`, `provider_id`, `started_at`)
- `AgentLauncher.run()` always calls `backend.start()` (fresh) — no resume path
- Multi-phase ingestion: Planner → Executors → Finalizer. Recommend persisting
  the planner session ID for simplicity (resume from planner phase)

## Implementation

### Step 1: Add acpSessionId to QueueItemPayload

`Sources/WikiFSCore/Core/QueueTypes.swift`:
```swift
public struct QueueItemPayload: Codable, Sendable {
    public var sourceIDs: [PageID]
    public var stageRouting: [String: String]?
    public var chainedItemID: String?
    public var lintPageIDs: [PageID]?
    /// ACP session ID for crash-resume. Set after session start, cleared on completion.
    public var acpSessionId: String?
}
```

### Step 2: Add QueueStore.updatePayload()

`Sources/WikiFSCore/Core/QueueStore.swift`:
```swift
public func updatePayload(id: QueueItem.ID, payload: QueueItemPayload) throws {
    try dbWriter.write { db in
        let data = try JSONEncoder().encode(payload)
        try db.execute(
            "UPDATE queue_items SET payload = ? WHERE id = ?",
            arguments: [String(data: data, encoding: .utf8)!, id]
        )
    }
}
```

### Step 3: Persist session ID on start

In `AgentLauncher.run()` after `backend.start()` returns a `SessionHandle`:
1. Read `backend.currentResumableSessionId()` (cast to ACPBackend if needed)
2. If non-nil, update the queue item payload via `QueueStore.updatePayload()`
3. This requires passing the queue item ID + a reference to QueueStore into the launcher

### Step 4: Attempt resume on dequeue

In `AppQueueIngestionProvider.runAgent()` before `launcher.run()`:
1. Read the queue item's payload
2. If `payload.acpSessionId` exists:
   - Cast backend to ACPBackend
   - Call `backend.resume(sessionID:profile:)`
   - If resume succeeds, proceed with the resumed session
   - If resume returns nil (not supported), fall back to fresh `backend.start()`
3. Log resume attempts/successes/failures via DebugLog

### Step 5: Clear session ID on completion

After successful ingestion, clear `acpSessionId` from the payload (no need to
resume a finished session).

### Step 6: Tests

- `QueueItemPayload` round-trips with `acpSessionId` (present + nil)
- `updatePayload()` persists and reloads correctly
- Resume path: payload with session ID → resume called → proceeds
- Fallback path: payload with session ID → resume returns nil → fresh start
- Completion clears the session ID
- Crash recovery: running→queued preserves the payload including session ID

## Files touched

- **Edit:** `Sources/WikiFSCore/Core/QueueTypes.swift` (add field)
- **Edit:** `Sources/WikiFSCore/Core/QueueStore.swift` (add updatePayload)
- **Edit:** `Sources/WikiFSEngine/AgentLauncher.swift` (persist session ID)
- **Edit:** `Sources/WikiFS/Queue/AppQueueIngestionProvider.swift` (resume attempt)
- **New:** `Tests/WikiFSTests/ACPResumeTests.swift`

## Acceptance criteria

- **AC.1**: `QueueItemPayload` includes optional `acpSessionId`.
- **AC.2**: `QueueStore.updatePayload()` updates the payload column.
- **AC.3**: Session ID persisted after `backend.start()`.
- **AC.4**: On dequeue with `acpSessionId`, resume is attempted before fresh start.
- **AC.5**: If resume returns nil, falls back to fresh start gracefully.
- **AC.6**: Session ID cleared on successful completion.
- **AC.7**: Crash recovery (`resetRunningToQueued`) preserves `acpSessionId`.
- **AC.8**: `swift build` + `swift test` pass.
