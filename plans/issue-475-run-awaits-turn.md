# Fix: `run()` awaits the turn (#475)

**Issue:** [#475](https://github.com/tqbf/selfdrivingwiki/issues/475)
**Branch:** `organic-moth` → new feature branch

## Problem

`AgentLauncher.run()` spawns the per-turn streaming loop as a fire-and-forget
`Task` (line 867) and returns immediately. The comment says so explicitly:

> *"fire-and-forget: run() returns after spawn commit; the stream is drained async."*

Since `run()` is `async`, the entire queue call chain resolves in ~7s (spawn +
preflight) while the agent streams for minutes:

```
QueueEngine.runWorker (:483)  → worker.execute (:483)
  → AppQueueIngestionProvider.runIngestion (:160) → runAgent (:289)
    → await launcher.run (:289)  ← returns after spawn, NOT after stream
      → Task { for await event in stream { ... } }  ← fire-and-forget
```

`handleWorkerFinished (:504)` → `store.markCompleted (:510)` marks the item
`completed` while the agent is still working.

A second defect compounds this: `onAgentEvent` is a single per-launcher stored
property (`:46`), not per-run keyed state. When two ingest items overlap:

1. Item A's `run()` installs `onAgentEvent = callbackA` at `:708`
2. `run()` fires off the stream `Task` and returns → item A is marked `completed`
3. Item B's `run()` blocks on `awaitGenerationSlot(for: .ingest)` at `:680`
   until item A's `finish()` releases the gate
4. Item A's stream `Task` is still alive — all its events hit whatever callback
   is installed (item A's, until item B's `resetRunArtifacts()` clears it at `:2082`)
5. Item B acquires the gate, clears the callback, spawns, completes with 0 events

Result: item A owns the entire transcript (17 events, 7.3s "duration"); item B
has zero events and 215.8s "duration" — but is the one shown as the long-running
ingest in the Activity window.

## Root cause (verified)

| Claim | Verified at |
|-------|-------------|
| `run()` returns before stream completes | `AgentLauncher.swift:855-882` — stream in `Task {}`, no `await` |
| `run()` is `async` (awaited by queue) | `AgentLauncher.swift:664-675` |
| Queue worker awaits `run()` → marks terminal on return | `QueueEngine.swift:483-491, 510` |
| `onAgentEvent` is single per-launcher property | `AgentLauncher.swift:46` |
| `resetRunArtifacts()` clears `onAgentEvent` | `AgentLauncher.swift:2082` |
| Gate serializes one-shot runs (no overlap) | `AgentLauncher.swift:680` — `awaitGenerationSlot(for: lane)` |

## Active callers of `run()`

Only two, both queue-based:

1. **`AppQueueIngestionProvider.runAgent`** (`:289`) — ingestion
2. **`AppQueueIngestionProvider.runLintAgent`** (`:322`) — lint

`AgentOperationRunner.runQuery` / `runLint` / `runLintPages` also call
`launcher.run()` but have **zero active call sites** (superseded by the queue;
grep confirmed no callers in `Sources/` or `Tests/`).

`startInteractiveQuery` (`:1396`) is a completely separate path — it has its
own spawn, its own `onExit`, does NOT call `run()`. Interactive turns use
`sendInteractiveMessage` (`:1628`), which **already inlines the stream loop**:

```swift
let stream = await backend.send(TurnInput(userText: trimmed), into: session)
for await event in stream {
    self.mergeOrAppend(event)
    if AgentEvent.endsGeneration(event) { ... }
}
```

This is the pattern `run()` should follow.

## Fix

### Change 1: Inline the stream consumption in `run()` (primary fix)

**File:** `Sources/WikiFSEngine/AgentLauncher.swift`, lines 855-882

**Before:**
```swift
// Consume the per-turn stream in a background Task (fire-and-forget:
// run() returns after spawn commit; the stream is drained async).
Task { @MainActor [weak self] in
    guard let self else { return }
    let stream = await backend.send(
        TurnInput(userText: promptText), into: session)
    for await event in stream {
        self.lastActivityAt = Date()
        self.mergeOrAppend(event)
        if AgentEvent.endsGeneration(event) {
            self.setGenerating(false)
            self.flushTranscript()
            if generationGateReleasesPerTurn {
                self.releaseGenerationSlot()
            }
        }
    }
}
```

**After:**
```swift
// Consume the per-turn stream INLINE so run() doesn't return until the
// turn completes. The queue worker awaits run() to decide when the item
// is done — an early return marks it completed while the agent is still
// streaming (#475). Mirrors sendInteractiveMessage's pattern.
let stream = await backend.send(
    TurnInput(userText: promptText), into: session)
for await event in stream {
    self.lastActivityAt = Date()
    self.mergeOrAppend(event)
    if AgentEvent.endsGeneration(event) {
        self.setGenerating(false)
        self.flushTranscript()
        if generationGateReleasesPerTurn {
            self.releaseGenerationSlot()
        }
    }
}

// Stream ended (turn complete or process died). If onExit hasn't fired
// yet (finish() not called), ensure teardown happens before run()
// returns so the caller sees post-finish state: gate released, run
// lifecycle decremented, onAgentEvent cleared. finish() is idempotent
// (isRunning guard), so a later onExit-triggered finish() is a safe
// no-op.
if isRunning {
    finish(status: exitStatus ?? 0)
}
```

**Why this is safe:**

- `run()` is `@MainActor` (class-level annotation). The `for await` suspends
  the main actor per event — it does NOT block the main actor or the queue
  engine's actor. Other main-actor work proceeds between events (exactly
  like `sendInteractiveMessage`).
- No `[weak self]` needed — `run()` is an instance method; the `await` keeps
  `self` alive for the duration (same as any async method).
- `finish()` is guarded by `isRunning` (line 1986) — calling it after the
  stream ends is safe whether or not `onExit` already called it.
- The watchdog (`startCompletionWatchdog`, `:1310`) still kills stuck
  processes via `stopAgent()` → `finish(-1)` → stream ends → the post-loop
  `finish(0)` is a no-op (isRunning already false).

### Change 2: Misattribution is naturally fixed (no code change needed)

With the inline await, two one-shot runs **cannot overlap**:

```
Item A: run() → gate acquire → spawn → for await stream → finish() → gate release → return
Item B: run() → awaitGenerationSlot(BLOCKED) → gate acquire → spawn → for await → finish() → return
```

`onAgentEvent` is installed fresh per run (`:708` after `resetRunArtifacts`
clears it at `:2082`) and cleared in `finish()` (`:2003`) before the next
run's `resetRunArtifacts()` runs. No overlap = no cross-attribution.

### Change 3 (optional, defense-in-depth): Key `onAgentEvent` per-run token

Not strictly required — the gate serialization already prevents overlap.
But if future changes break that guarantee, a stale callback could again
receive events. A run-token check would make this impossible:

```swift
// In run(), capture alongside currentRunToken:
let onEventToken = UUID()

// Store both the callback AND the token:
@ObservationIgnored private var onAgentEventEntry: (token: UUID, callback: @Sendable (AgentEvent) -> Void)?

// In mergeOrAppend, only fire if the token matches the current run:
if let entry = onAgentEventEntry, entry.token == currentRunToken {
    entry.callback(event)
}
```

**Defer** unless we want belt-and-suspenders. The inline await is the real fix.

### Change 4 (optional, secondary): Replace `try?` with logged error at the write seam

**File:** `Sources/WikiFSEngine/QueueEngine.swift`, line 362

```swift
// Before:
try? store.appendItemEvent(itemID: id, event: event)

// After:
do {
    try store.appendItemEvent(itemID: id, event: event)
} catch {
    DebugLog.store("QueueEngine: appendItemEvent failed for item=\(id): \(error)")
}
```

The issue notes this isn't the cause (writes succeed, just against the wrong
item) but flags it as the same silent-swallow pattern that lost transcripts
before (documented at `QueueStore.swift:156-160`).

## What NOT to change

- **`startInteractiveQuery` / `sendInteractiveMessage`** — already correct
  (inline stream consumption). No changes needed.
- **`QueueEngine` dispatch / worker model** — the queue correctly awaits
  `worker.execute()` and marks terminal on return. The bug was `run()`
  returning early, not the queue logic.
- **`onExit` callback** — still needed for the case where the process dies
  before the stream's `for await` gets to consume all events (e.g., SIGKILL).
  The post-stream `finish()` is the safety net for the normal case; `onExit`
  handles the abnormal case.

## Test plan

### Regression test: `run()` does not return until the stream completes

Add a test using a stub backend that:
1. Returns a session from `start()`
2. Returns an `AsyncStream` from `send()` that yields 3 events, then finishes
3. Asserts the caller's continuation resumes only after all 3 events are
   consumed (not after spawn)
4. Asserts `finish()` was called (gate released, `isRunning == false`)

### Existing tests to verify

- `AgentLauncher` unit tests (stub backend) — should still pass since the
  stream loop body is unchanged
- `QueueEngine` tests — should still pass (worker still awaits `execute()`)
- Fast tier: `swift test --skip 'EnumeratorDeletionTests|...'`

## Risk assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Main actor blocked during long ingest | Low — `await` suspends, doesn't block | Medium | Same as `sendInteractiveMessage`; verified by existing interactive sessions |
| `finish(status: 0)` before `onExit` fires hides real exit status | Low — stream completing means turn was done; post-turn crash is unusual | Low | `exitStatus` is UI display only; `onExit` `finish()` is a no-op |
| Existing tests rely on `run()` early return | Low — no tests call `launcher.run` directly (grep confirmed) | Low | Run full test suite to verify |
