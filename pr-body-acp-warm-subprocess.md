## ACP Session Efficiency Phase 1: Warm Subprocess Across Ingest Phases

Closes #525. Implements Phase 1 of `plans/acp-session-efficiency.md`.

### Problem

The multi-phase ACP ingest pipeline (`runACPIngestPlannerExecutors`) called
`backend.start()` (full launch + initialize + authenticate + newSession + setModel
+ drain setup) and `backend.cancel()` (cancelSession + terminate — kills the
subprocess) **per phase**. For a 5-source ingest, that's 7 complete subprocess
lifecycles, wasting 12–24s on process plumbing alone.

### Solution

Separate the **process lifecycle** (launch + initialize + authenticate) from
the **session lifecycle** (newSession + setModel + fanout):

- **One subprocess** spawned at the beginning of the ingest
- **Per-phase**: `session/new` + `send` + `session/close` (frees session context
  WITHOUT killing the subprocess)
- **One `terminate()`** at the very end

This eliminates 6 subprocess spawn/teardown cycles for a 5-source ingest.

### Changes

**`ACPBackend.swift`:**
- New `WarmProcess` struct: holds the `Client`, `permissionDelegate`,
  `InitializeResponse`, process-lifetime `NotificationFanout`, drain task, stderr
  task, and `canCloseSession` capability flag
- `start()` refactored to call `startProcess()` (launch + initialize + authenticate
  + drain + stderr, idempotent if warm process exists) then `createSession()`
- New `createSession()`: creates an ACP session (newSession + setModel + system
  prompt delivery) on an already-warm subprocess
- New `closeSession(_:)`: cancels in-flight work, calls `client.closeSession()`
  (if `sessionCapabilities.close` is advertised), removes the session from the map,
  but does NOT terminate the subprocess. Degrades gracefully if close is unsupported
- `cancel()` updated to tear down the `WarmProcess` (drain + stderr + fanout +
  terminate) in addition to the session record — handles both the "session still
  active" and "session already closed" cases

**`AgentLauncher.swift`:**
- `runACPIngestPlannerExecutors`: phase boundaries now call `closeSession()`
  instead of `cancel()`. At the very end, all backends in `stageBackendCache` are
  cancelled (terminating their warm subprocesses)
- `stopAgent()` unchanged — already calls `backend.cancel()` which now tears down
  both session and warm process
- `runACPIngestFallback` unchanged — its `cancel()` call is terminal and
  correctly tears down the warm process

### Backwards Compatibility

- `start()` retains its `AgentBackend` protocol signature — interactive chat paths
  (`startInteractiveQuery`, `run`) work unchanged
- `cancel()` retains its signature and semantics (full teardown)
- `closeSession()` is ACP-specific (not on the protocol) — the orchestrator
  downcasts to `ACPBackend` and falls back to `cancel()` for non-ACP backends

### Capability Detection

At `initialize` time, `agentCapabilities.sessionCapabilities?.close` is checked.
If the agent doesn't support `session/close`, `closeSession()` degrades to
`cancelSession` only (the session context is leaked until process termination —
a memory cost, not a correctness issue).

### Testing

- `swift build` passes
- Fast test tier (2456 tests) passes — no regressions
- No new tests needed for Phase 1: the `closeSession`/`createSession` methods
  require a live ACP subprocess to test end-to-end (the spike forbids live-agent
  testing). Pure logic (capability detection, session map management) is
  exercised by the existing ACPBackendTests suite
