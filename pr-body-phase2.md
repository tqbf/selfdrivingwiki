## ACP session efficiency Phase 2: session/resume crash recovery

Implements `session/resume` crash recovery per `plans/acp-session-efficiency.md` Phase 2. When the agent subprocess dies silently (issue #338: `claude-agent-acp` stays alive but all sessions break), this provides a recovery path: spawn a new subprocess and restore the session without replaying history.

### Changes

**1. Capability detection at init time**

`startProcess()` now captures `sessionCapabilities.resume`, `agentCapabilities.loadSession`, and `sessionCapabilities.list` from the `InitializeResponse`, stored on the `WarmProcess` struct alongside the existing `canCloseSession`:

```swift
let canResume = sessionCaps?.resume != nil
let canLoadSession = initResponse.agentCapabilities.loadSession == true
let canListSessions = sessionCaps?.list != nil
```

**2. Session ID tracking for resumption**

- `resumableSessionId: SessionId?` field on the actor — tracks the last active ACP session ID
- Set in `createSession()` and `registerResumedSession()`
- Cleared in `closeSession()` (intentional close — not a crash) and `cancel()` (full teardown)
- `savedOnExit` callback saved so `resume()` can re-bind it on a new subprocess

**3. `resume()` implementation (was returning `nil`)**

The fallback chain per the design doc:

| Capability | Recovery path | Cost |
|---|---|---|
| `sessionCapabilities.resume` | `resumeSession` — zero replay | Fastest |
| `loadSession: true` | `loadSession` — replays history as notifications | O(history) |
| Neither | Return `nil` — caller falls back to fresh `start()` | Loses context |

`resume()` also tears down the old (dead) warm process before spawning a new one via `startProcess()`.

**4. Subprocess death detection**

Two detection layers:

- **Watchdog health check**: the `TurnLivenessPolicy` watchdog's `.stalled` case now checks `kill(pid, 0)` before declaring a stall. If the process is actually dead, it fires `.processDied` instead of `.turnStalled` and sets a `ProcessHealthFlag` so the prompt task short-circuits.
- **sendPrompt error**: the prompt task's `catch` block marks the `ProcessHealthFlag` dead, so the watchdog doesn't try to `cancelSession` on a dead process.

New `.processDied` error case on `ACPBackendError` surfaces the death to the caller.

**5. Public query methods**

- `isProcessAlive() async -> Bool` — liveness probe via `kill(pid, 0)`
- `currentResumableSessionId() -> SessionId?` — the ACP session ID for crash recovery

### What's NOT in this PR

- **Orchestrator integration**: the `recoverAndResume` flow in `runACPIngestPlannerExecutors` — deferred to avoid coupling the orchestrator change with the backend change. The backend seam (`resume()`, `isProcessAlive()`, `currentResumableSessionId()`) is ready for the orchestrator to consume.
- **Queue DB persistence**: the design doc mentions storing `acpSessionId` in `QueueItem` payload. This is a follow-up; the in-memory `resumableSessionId` covers the within-run crash recovery case.
- **Interactive chat resume**: Phase 2 focuses on multi-phase ingest; interactive chat resume is a future enhancement.

### Testing

All 2456 fast-tier tests pass. The existing `FakeAgentBackend.resume` returns `nil` (unchanged). Unit tests for the new capability detection and resume fallback chain will follow once the orchestrator is wired (they need a fake `Client` actor, which requires the test harness from the orchestrator change).
