# ACP session efficiency — warm subprocess, context-aware sessions, crash recovery

**Issue:** https://github.com/tqbf/selfdrivingwiki/issues/525
**Branch:** `design/acp-session-efficiency`
**Status:** Design (research; not yet implemented)

## Problem

The multi-phase ACP ingest pipeline (`runACPIngestPlannerExecutors` in
`Sources/WikiFSEngine/AgentLauncher.swift`) spawns a **new subprocess per phase**
— planner, each executor, finalizer. Each phase runs a complete
`start()` → `send()` → `cancel()` lifecycle:

```
runACPIngestPlannerExecutors
  ┌───────────────────────────────────────────────┐
  │ Phase 1: Planner                               │
  │   backend.start()  → launch + initialize +     │
  │     authenticate + newSession + setModel +      │
  │     drain-task setup                            │  ~2–4s overhead
  │   backend.send(plannerPrompt)                   │
  │   backend.cancel()  → cancelSession + terminate  │  ~1–2s teardown
  ├───────────────────────────────────────────────┤
  │ Phase 2: Executor[source-1]                     │
  │   backend.start()  → FULL lifecycle again        │  ~2–4s overhead
  │   backend.send(executorPrompt)                  │
  │   backend.cancel()                               │  ~1–2s teardown
  ├───────────────────────────────────────────────┤
  │ Phase 2: Executor[source-2]  ... (repeat)       │
  ├───────────────────────────────────────────────┤
  │ Phase 3: Finalizer                              │
  │   backend.start()  → FULL lifecycle again        │  ~2–4s overhead
  │   backend.send(finalizerPrompt)                 │
  │   backend.cancel()                               │  ~1–2s teardown
  └───────────────────────────────────────────────┘
```

For a 5-source ingest this is **7 complete subprocess lifecycles**, each with
~2–4s of launch + initialize + authenticate + newSession + setModel + drain
setup overhead, plus ~1–2s teardown. That's **12–24s wasted** on process
plumbing alone.

The swift-acp SDK (`wsargent/swift-acp`, v0.2.0+) already exposes a rich
session lifecycle that we don't use:

| SDK method | What it does | Currently used? |
|---|---|---|
| `client.newSession(cwd:)` | Create a new session on the running subprocess | ✅ Yes (in `start()`) |
| `client.sendPrompt(sessionId:content:)` | Send a turn; blocks until turn completes | ✅ Yes (in `send()`) |
| `client.cancelSession(sessionId:)` | Cancel an in-flight turn | ✅ Yes (in `send()` watchdog + `cancel()`) |
| `client.closeSession(sessionId:)` | Free session context **without killing the subprocess** | ❌ No |
| `client.resumeSession(sessionId:cwd:...)` | Restore a session without history replay (crash recovery) | ❌ No (`resume()` returns `nil`) |
| `client.forkSession(sessionId:cwd:...)` | Branch a conversation (child inherits parent context) | ❌ No |
| `client.listSessions(cwd:)` | List persisted sessions on the subprocess | ❌ No |
| `client.loadSession(sessionId:cwd:...)` | Reload a session by replaying history (O(history)) | ❌ No |
| `client.terminate()` | Kill the subprocess; finishes notification stream | ✅ Yes (in `cancel()`) |
| `client.processIdentifier()` | Read the subprocess PID (watchdog kill-escalation) | ✅ Yes (`captureProcessID`) |

---

## 1. Current architecture analysis

### The `start()` → `send()` → `cancel()` contract

Today's `ACPBackend` (actor) models a **one-to-one mapping between a subprocess
and a session**: every `start()` call performs the full lifecycle:

1. `Client()` — create a new SDK Client actor
2. `client.launch(agentPath:arguments:environment:)` — spawn the subprocess
3. `client.initialize(protocolVersion:capabilities:clientInfo:)` — ACP handshake
4. `ACPAuthResolver.resolve(...)` → `client.authenticate(...)` (if authMethods
   advertised)
5. `Self.deliverSystemPrompt(...)` — write `CLAUDE.md`/`AGENTS.md` to cwd
6. `client.newSession(workingDirectory:)` — create an ACP session
7. `ACPModelSelectionResolver.resolve(...)` → `client.setModel(...)` (if user
   selected a model)
8. Start the session-lifetime notification drain task (`NotificationFanout`)
9. Start the stderr forwarding task
10. Store an `ACPSession` record keyed by a UUID `SessionHandle.id`

Steps 1–9 are ~2–4s of wall-clock overhead. Every `cancel()` does:
`client.cancelSession` + `client.terminate()`, killing the subprocess.

### The multi-phase orchestrator

`runACPIngestPlannerExecutors` calls `runPhase()` per phase. Each `runPhase()`
calls `backend.start()` + `backend.send()` + returns the session handle. The
orchestrator then calls `backend.cancel(session)` at the phase boundary.

The `stageBackendCache` (`[String: AgentBackend]`) keyed by
`providerId|modelId` only avoids constructing redundant backend **actor**
instances — it does NOT avoid spawning a new subprocess per phase, because
`start()` always spawns and `cancel()` always terminates.

> **The core inefficiency:** `start()` and `cancel()` are the wrong
> granularity. The subprocess lifecycle (launch + initialize + authenticate)
> should span the whole ingest; the session lifecycle (newSession + send +
> closeSession) should span one phase.

### Key data structures

```swift
// ACPBackend.swift — current one-session-per-subprocess model
private struct ACPSession: Sendable {
    let client: Client                    // the SDK actor (owns the subprocess)
    let sessionId: SessionId              // ACP's session id (SessionId.value: String)
    let permissionDelegate: ACPPermissionDelegate
    let modelsInfo: ModelsInfo?
    let notificationFanout: NotificationFanout
    let drainTask: Task<Void, Never>?
    let systemPrompt: String
    var systemPromptInjected: Bool
}

private var sessions: [String: ACPSession] = [:]  // key = UUID SessionHandle.id
```

The `Client` actor IS the subprocess — it owns the `ACPProcessManager` which
owns the `Process`. `terminate()` kills the process and finishes the
notification stream. `closeSession()` only frees the session's context on the
agent side.

### SDK capability types

The `InitializeResponse` carries `agentCapabilities: AgentCapabilities`, which
has `sessionCapabilities: SessionCapabilities?` with optional sub-capabilities:

```swift
// ACPModel/Capabilities.swift
public struct SessionCapabilities: Codable, Sendable {
    public let additionalDirectories: SessionAdditionalDirectoriesCapabilities?
    public let close: SessionCloseCapabilities?           // session/close
    public let delete: SessionDeleteCapabilities?         // session/delete
    public let fork: SessionForkCapabilities?             // session/fork
    public let list: SessionListCapabilities?             // session/list
    public let resume: SessionResumeCapabilities?         // session/resume
}
```

Each sub-capability is a marker struct (presence = supported; absence =
unsupported). We must check these at `initialize()` time and degrade
gracefully when absent.

### Usage tracking types

The `session/update` notification's `.usageUpdate(UsageUpdate)` case carries
real-time context window and cost data:

```swift
// ACPModel/Updates.swift
public struct UsageUpdate: Codable, Sendable {
    public let used: Int       // tokens consumed so far
    public let size: Int       // total context window size
    public let cost: Cost?
    public let _meta: [String: AnyCodable]?
}

public struct Cost: Codable, Sendable {
    public let amount: Double
    public let currency: String  // e.g. "USD"
}

public struct Usage: Codable, Sendable {  // in SessionPromptResponse
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedReadTokens: Int?
    public let cachedWriteTokens: Int?
    public let thoughtTokens: Int?
    public let totalTokens: Int
}
```

Currently `ACPEventTranslator.translate()` **discards** `.usageUpdate` — it
returns `[]` (no AgentEvent). The per-turn `SessionPromptResponse.usage` is
also discarded (`send()` only reads `stopReason`).

---

## 2. Phase 1 design: warm subprocess + per-phase session lifecycle

**Goal:** One subprocess for the entire ingest; per-phase sessions opened and
closed without killing the process. This alone eliminates 6 subprocess
spawn/teardown cycles for a 5-source ingest.

### Architecture

```
runACPIngestPlannerExecutors
  ┌─────────────────────────────────────────────────────┐
  │  ONE long-lived ACP subprocess                       │
  │  (spawned once at ingest start)                      │
  │                                                      │
  │  ┌──────────────┐                                   │
  │  │  Session A     │  PLANNER (warm, multi-turn)      │
  │  │  session/new   │  reads sources → plan.json       │
  │  └──────┬───────┘                                   │
  │         │ session/close (free context, keep process) │
  │         ▼                                            │
  │  ┌────────────────────────────────────────┐         │
  │  │  Session B₁  B₂  ... Bₙ                │ EXECUTORS│
  │  │  session/new (or fork) per source        │ (serial) │
  │  │  within each: warm multi-turn            │         │
  │  │  session/close each                       │         │
  │  └──────┬─────────────────────────────────┘          │
  │         │ session/close each                          │
  │         ▼                                            │
  │  ┌──────────────┐                                   │
  │  │  Session C     │  FINALIZER                       │
  │  │  session/new   │  → final wiki pages              │
  │  └──────────────┘                                   │
  │                                                      │
  │  terminate() at the very end                         │
  └─────────────────────────────────────────────────────┘
```

### ACPBackend changes

#### 2.1 Refactor `start()` into subprocess-start + session-create

The current `start()` conflates two concerns: **subprocess lifecycle** (launch
+ initialize + authenticate) and **session lifecycle** (newSession + setModel +
fanout + drain). Phase 1 separates these.

**New internal structure:** `ACPBackend` gains a notion of a "warm process" —
a `Client` actor that has been launched + initialized + authenticated but has
no active session. Multiple sessions can be created and closed on it.

```swift
public actor ACPBackend: AgentBackend {

    /// A launched+initialized+authenticated subprocess with no active session,
    /// or one that has sessions opened on it. This is the warm-process state.
    private struct WarmProcess: Sendable {
        let client: Client
        let permissionDelegate: ACPPermissionDelegate
        let initResponse: InitializeResponse
        let notificationFanout: NotificationFanout
        let drainTask: Task<Void, Never>
        let stderrTask: Task<Void, Never>?
        let syncLock: NSLock          // guards session creation/close serialization
    }

    private var warmProcess: WarmProcess?       // at most one warm process
    private var sessions: [String: ACPSession] = [:]

    // Phase 1: start() still does the full lifecycle (subprocess + session),
    //          backwards-compatible. Internally it calls startProcess() +
    //          createSession().
    //          A NEW method, startProcess(), is the seam for warm-reuse.

    /// Launch + initialize + authenticate. Returns a handle to the warm
    /// process. Idempotent: if a warm process already exists and is alive,
    /// reuses it. If the process died, spawns a new one.
    private func startProcess(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> WarmProcess

    /// Create a new ACP session on the warm process. Does NOT spawn a
    /// subprocess. Delivers the system prompt, creates the session, applies
    /// model selection, returns a SessionHandle.
    private func createSession(
        on process: WarmProcess,
        profile: BackendProfile,
        systemPrompt: String
    ) async throws -> SessionHandle
}
```

**Backwards compatibility:** `start()` retains its current signature
(`AgentBackend.start`), calling `startProcess()` then `createSession()` — so
interactive chat paths (`startInteractiveQuery`) keep working unchanged.

#### 2.2 New `closeSession()` method

```swift
/// Close a session WITHOUT terminating the subprocess. Frees the session's
/// context on the agent side. The subprocess stays alive for reuse by a
/// subsequent `createSession()` or `start()` call. No-op if the session is
/// already gone. Checks sessionCapabilities.close at first use; if unsupported,
/// falls back to a no-op (the session context will be freed when the process
/// eventually terminates — the cost is leaked memory, not correctness).
public func closeSession(_ handle: SessionHandle) async
```

Implementation:
1. Remove the `ACPSession` record from `sessions[handle.id]`.
2. Cancel the per-session drain sub-task (if any — in Phase 1, the drain is
   process-lifetime, so it stays; only the fanout subscription per-turn is
   per-session).
3. `try? await client.closeSession(sessionId: record.sessionId)` — best-effort.
4. Drain any in-flight always-ask continuations for this session.
5. Do NOT call `client.terminate()`.

#### 2.3 `cancel()` retains its current behavior

`cancel()` still calls `cancelSession` + `terminate` + `fireOnExit` — it is the
full teardown. Used for interactive chat teardown and `stopAgent()`. For
ingest, Phase 1 uses `closeSession()` at phase boundaries and `cancel()` at the
very end.

#### 2.4 Orchestrator changes

`runACPIngestPlannerExecutors` gains a warm-process lifecycle:

```swift
// --- At the very start: spawn ONE subprocess ---
// The first resolveStageRouting → runPhase still calls backend.start(),
// which does the full launch + initialize + authenticate + newSession.
// After the planner phase, instead of cancel(), we call closeSession().
// The next runPhase calls backend.start() AGAIN — but start() now checks
// for a warm process and reuses it, skipping launch+initialize.

// --- Per-phase ---
// Planner:   start() [warm-process-aware] → send → closeSession()
// Executor:  start() [reuses warm process, only newSession] → send → closeSession()
// Finalizer: start() [reuses warm process, only newSession] → send → closeSession()

// --- At the very end ---
// backend.cancel() terminates the subprocess
```

**Key change in `runPhase`:** after `backend.send()` drains, instead of
returning the session for the orchestrator to `cancel()`, the orchestrator
calls `closeSession()`. The `runPhase` helper itself doesn't change — it still
calls `backend.start()` + `backend.send()`, and returns the handle. The
**caller** changes from `backend.cancel(session)` to
`(backend as? ACPBackend)?.closeSession(session) ?? await backend.cancel(session)`.

**Stage routing interaction:** stages may resolve to different providers. If
the executor stage uses a different provider than the planner, a NEW warm
process must be spawned for the executor's backend. The warm-process reuse is
per-backend (per `ACPBackend` actor instance), and `stageBackendCache` already
keeps at most one backend per `(providerId, modelId)`. So warm-process reuse
happens when stages share a resolution, which is the common case (same provider
for planner + executor, just different models — and `setModel` is per-session).

If stages resolve to different providers, each gets its own `ACPBackend` with
its own warm process. That's still better than today: each backend spawns once
and reuses across its own phases. A 3-provider ingest (planner on Opus,
executor on Sonnet, finalizer on Opus) goes from 7 subprocess lifecycles to 2
(Opus backend: planner + finalizer share; Sonnet backend: all executors share).

#### 2.5 `stopAgent()` interaction

`stopAgent()` calls `backend.cancel(session)` which does `cancelSession` +
`terminate`. This is correct for Phase 1: if the user hits Stop during any
phase, the subprocess is terminated. Remaining phases skip (checked via
`isRunning` guard). The warm process is killed; no further `start()` calls
will reuse it. This matches today's behavior — Stop kills the process.

**Subtle invariant:** `closeSession()` is called by the orchestrator AFTER
`runPhase` returns (i.e., after the turn stream has drained). `stopAgent()`
fires during the stream's `for await` — so `closeSession` is never reached if
Stop fires mid-phase. The `isRunning` guard in the orchestrator's loop catches
this.

#### 2.6 Notification drain interaction

The session-lifetime notification drain (cause 6 fix from
`plans/acp-stall-recovery.md`) is currently started in `start()` and cancelled
in `cancel()`. In Phase 1, the drain becomes **process-lifetime** (started in
`startProcess()`, cancelled in `cancel()`/`terminate()`). Each `createSession`
creates a new `ACPSession` record that subscribes to the same `NotificationFanout`.
`closeSession()` does NOT finish the fanout — only `cancel()` does.

This is safe because the generation gate serializes turns: at most one session
is actively prompting at a time, so the fanout's single-subscriber invariant is
preserved.

#### 2.7 `--bare` mode consideration

Research found that `--bare` mode skips hooks/skills/plugins auto-discovery,
giving faster startup. This is a spawn-config change (add `--bare` to
`AgentSpawnConfig.arguments`), not a session-lifecycle change. It's
complementary to Phase 1 but orthogonal — the spawn is amortized from 7× to 1×,
and `--bare` makes that 1× faster. Recommend adding in the Phase 1
implementation PR as a spawn-config option toggled by a provider hint.

---

## 3. Phase 2 design: `session/resume` crash recovery

**Goal:** If the subprocess dies mid-ingest (issue #338 — silent death),
spawn a new one and resume the session without replaying history. If resume
isn't supported, fall back to `session/load` (full replay) or a fresh
session.

### Capability detection

At `startProcess()` time, after `client.initialize(...)`, capture:

```swift
let canResume = initResponse.agentCapabilities.sessionCapabilities?.resume != nil
let canLoad   = initResponse.agentCapabilities.loadSession == true
let canClose  = initResponse.agentCapabilities.sessionCapabilities?.close != nil
let canFork   = initResponse.agentCapabilities.sessionCapabilities?.fork != nil
```

Store these on the `WarmProcess` record so subsequent session operations can
check support.

### Session ID persistence

The ACP `SessionId` (from `NewSessionResponse.sessionId`) is the key for
resume/load. It must persist across subprocess death. Currently it lives only
in-memory on the `ACPSession` record.

**Storage location:** the queue DB. The ingestion `QueueItem` payload is a
JSON `Codable`. Add an optional `acpSessionId: String?` field to the ingest
payload that the orchestrator updates after each phase's `session/new`. This
survives not only subprocess death but also app relaunch (if the queue is
paused mid-ingest).

For interactive chat sessions, the `SessionHandle.id` (our internal UUID) is
already persisted on the chat row as `session_id` + `backend_kind`. Phase 2
extends the chat schema to store the **ACP** session id alongside it (a new
`acp_session_id` column, migration-safe).

### Death detection

Subprocess death is silent (issue #338): `claude-agent-acp` stays alive but
sessions break, and the SDK's `Client.terminate` may not fire `onExit` in all
cases. Detection strategies, layered:

1. **SDK `onExit`/termination callback** (primary): `processManager`'s
   `terminationCallback` fires when the OS reports the process gone. The
   `ACPBackend` binds this to `fireOnExit`. In Phase 2, `ACPBackend` also sets
   an internal `processIsAlive = false` flag so the next `start()` /
   `send()` call knows the process is dead.

2. **`sendPrompt` error** (secondary): if the process died but `onExit` hasn't
   fired yet, `client.sendPrompt` will throw (the transport's pipe is broken).
   `ACPBackend.send()`'s catch block already turns this into turn-end events.
   Phase 2 adds: on a `ClientError.processNotRunning` or transport error,
   mark the process dead and attempt resume.

3. **Health-check ping** (tertiary, optional): a lightweight
   `client.listSessions(cwd:)` call on a timer. If it throws or returns
   empty when sessions should exist, the process is dead. Low priority — the
   first two signals cover most cases.

### Resume flow

```
Phase N: send() in progress → process dies
  1. sendPrompt throws → send() synthesizes turnEndEvents(error)
  2. ACPBackend marks warmProcess.processIsAlive = false
  3. Orchestrator's runPhase returns nil (phase failed)
  4. NEW: orchestrator calls backend.recoverAndResume(sessionId:cwd:)
     a. startProcess() spawns a new subprocess (launch + initialize + auth)
     b. client.resumeSession(sessionId:cwd:) — restores context without replay
     c. If resume throws (unsupported / session GC'd):
        - try client.loadSession(sessionId:cwd:) — full replay
        - if that also fails: restart the phase with a fresh session/new
     d. Re-send the phase prompt (the agent's context is restored; the prompt
        is idempotent because it reads artifacts from disk)
  5. continue with the next phase
```

**`ACPBackend.resume()` implementation (currently returns `nil`):**

```swift
public func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
    // sessionID is the ACP SessionId.value, not our internal UUID.
    guard let process = warmProcess, !process.processIsAlive else {
        // Process still alive — no resume needed (or start a new one)
        return nil
    }
    // Spawn a new subprocess
    let newProcess = try await startProcess(
        profile: profile, systemPrompt: "", onExit: { _ in })
    // Resume the session on the new process
    let cwd = profile.scratchDirectory?.path ?? FileManager.default.currentDirectoryPath
    do {
        _ = try await newProcess.client.resumeSession(
            sessionId: SessionId(sessionID), cwd: cwd)
        // Create a new SessionHandle wrapping the resumed session
        let handle = SessionHandle(id: UUID().uuidString)
        sessions[handle.id] = ACPSession(
            client: newProcess.client, sessionId: SessionId(sessionID), ...)
        return handle
    } catch {
        // Resume not supported or session GC'd — fall back to loadSession
        if newProcess.initResponse.agentCapabilities.loadSession == true {
            _ = try await newProcess.client.loadSession(
                sessionId: SessionId(sessionID), cwd: cwd)
            // ... create handle, return
        }
        // Neither resume nor load — return nil; caller restarts with fresh session
        return nil
    }
}
```

### Fallback chain

| Capability | Recovery path | Cost |
|---|---|---|
| `sessionCapabilities.resume` supported | `resumeSession` — zero replay | Fastest |
| `loadSession: true` supported | `loadSession` — replays all history as notifications | O(history); expensive for long sessions |
| Neither supported | Fresh `session/new` + re-send the phase prompt | Loses context; works because prompts are artifact-based |

### When NOT to resume

- **Cross-phase boundaries:** don't resume a planner session to run an
  executor — the contexts are different (cold sessions, per the matrix).
- **Interactive chat:** resume is valuable for crash recovery, but the chat
  path's `onExit` already drives `finish()`. Phase 2 resume for interactive
  is a future enhancement; the immediate value is for multi-phase ingest.

---

## 4. Phase 3 design: `session/fork` for executors

**Goal:** After the planner produces `plan.json`, fork the planner's session
for each executor. The executor inherits the planner's understanding of source
layout without the reasoning noise (intermediate tool calls, failed
attempts).

### When fork helps

The planner session accumulates valuable context: it has read all source
files, established their structure, and synthesized a plan. An executor that
forks from this session starts with that understanding already in context —
it doesn't need to re-read the source layout to find the relevant sections.

Without fork, each executor starts cold: `session/new` → re-reads
`plan.json` from disk → re-reads the source file → finds the relevant section.
With fork, the executor starts with the source layout already understood and
can go straight to extraction.

### Fork flow

```
Phase 1: Planner
  session/new → send (reads sources, writes plan.json) → session/close
  
  BUT: don't close! Keep the planner session alive for forking.

Phase 2: Executor[source-1]
  session/fork (from planner session) → executorSession₁
  send (reads source ranges, writes pages) → session/close (executorSession₁)

Phase 2: Executor[source-2]
  session/fork (from planner session) → executorSession₂
  send → session/close
  ...
  session/close (planner session — now that all forks are done)
```

### Fork vs. fresh session — decision logic

```swift
// After planner produces plan.json:
if warmProcess.initResponse.agentCapabilities.sessionCapabilities?.fork != nil {
    // Fork: executor inherits planner's source context
    let forkedHandle = try await backend.forkSession(
        from: plannerHandle, cwd: scratch.path)
    // ... send executor prompt on forkedHandle
} else {
    // Fresh session: executor reads plan.json from disk (current behavior)
    let freshHandle = try await backend.start(profile: executorProfile, ...)
    // ... same as today
}
```

### Fork timing

**Fork one-at-a-time (serial executors):** fork → send → close, repeat. The
planner session stays alive as the fork source throughout Phase 2. This is the
simplest and most conservative — executors run serially (as they do today).

**Fork all-at-once (parallel executors, Phase 4):** fork N sessions before
sending any prompts, then send all N in parallel via `withTaskGroup`. The
planner session is the fork source; all N forks exist simultaneously. Phase 4
extends Phase 3's fork to parallel.

**Recommendation:** Phase 3 implements serial fork-one-at-a-time. Phase 4
extends to parallel.

### `ACPBackend.forkSession`

```swift
/// Fork a session: the new session inherits the parent's conversation context
/// but is independent going forward. Returns a new SessionHandle for the fork.
/// nil if fork is not supported.
public func forkSession(from handle: SessionHandle, cwd: String) async throws -> SessionHandle?
```

Implementation:
1. Guard the parent session exists.
2. Guard `sessionCapabilities.fork != nil`.
3. `let response = try await client.forkSession(sessionId: parent.sessionId, cwd: cwd)`
4. The `ForkSessionResponse` carries a new `sessionId: SessionId`.
5. Create a new `ACPSession` record for the forked session (same client, same
   fanout — the fork shares the subprocess's notification stream).
6. Return a new `SessionHandle`.

### Planner session lifetime change

Currently the planner session is closed (or cancelled) immediately after the
planner phase. With fork, the planner session must stay alive until all
forks are created. The orchestrator:

1. **Planner:** `start()` → `send()` → do NOT `closeSession()` yet.
2. **Executor loop:** `forkSession(from: plannerHandle)` → `send()` →
   `closeSession(executorHandle)` per source. If fork unsupported, fall back
   to `start()` → `send()` → `closeSession()` (fresh session each time).
3. **After all executors:** `closeSession(plannerHandle)` — the planner
   session has served its purpose as a fork source.

### Interaction with the system prompt injection

The current `send()` injects the system prompt into the first turn's user
text via `systemPromptInjected` flag. A forked session inherits the parent's
context — including the already-injected system prompt. So `systemPromptInjected`
should be `true` on the forked session (set at fork creation time).

---

## 5. Phase 4 design: parallel executors + context monitoring

**Goal:** Run N executor sessions in parallel on one subprocess (if concurrent
sessions are supported) or a small pool of subprocesses (if not). Monitor
context window usage and proactively manage sessions before exhaustion.

### Concurrent session support

The ACP spec supports concurrent sessions on one subprocess — `session/new`
can be called multiple times, and `session/prompt` can be called on different
sessions concurrently. But whether `claude-agent-acp` (or any specific agent)
handles concurrent `session/prompt` calls reliably is **untested**.

**Testability:** `client.newSession` + `client.sendPrompt` on two sessions
concurrently is the probe. A test agent (or the production agent in a smoke
test) can verify this. The `listSessions` call confirms both sessions exist.

**If unsupported:** spawn a small pool of subprocesses (2–3), distributing
executors across them. Each subprocess runs executors serially (or with its
own concurrent sessions if supported). This is the pool model from the issue.

### Parallel executor flow

```swift
// Phase 2: Parallel executors
let executors = plan.distinctSourceFiles
let routing = resolveStageRouting(.executor, ...)

if agentSupportsConcurrentSessions {
    // Parallel: fork all at once, send all in parallel
    let forkedSessions = try await withThrowingTaskGroup(of: SessionHandle?.self) { group in
        for sourceFile in executors {
            group.addTask {
                try await backend.forkSession(from: plannerHandle, cwd: scratch.path)
            }
        }
        // Collect all forked handles
        var handles: [SessionHandle?] = []
        for try await handle in group { handles.append(handle) }
        return handles
    }
    
    // Now send prompts in parallel
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (handle, sourceFile) in zip(forkedSessions, executors) {
            guard let handle else { continue }
            let prompt = ACPIngestPrompts.executorPrompt(...)
            group.addTask {
                let stream = await backend.send(TurnInput(userText: prompt), into: handle)
                for await event in stream { /* mergeOrAppend */ }
                await backend.closeSession(handle)
            }
        }
        try await group.waitForAll()
    }
} else {
    // Pool model: spawn 2–3 subprocesses, distribute executors
    let poolSize = min(3, executors.count)
    // ... distribute executors across pool
}
```

### Context monitoring via `usage_update`

The `session/update` notification's `.usageUpdate(UsageUpdate)` case carries
`used` and `size` — the context window consumption and total size. Currently
discarded. Phase 4 captures it for proactive management:

| Usage ratio | Action |
|---|---|
| < 50% | Healthy — continue |
| 50–64% | Log a warning (context rot begins around 25% per Chroma 2025 study, but 64% is the "turbo" threshold) |
| ~64% | Trigger proactive artifact write (flush partial results to disk so a fresh session can continue) |
| ~80% | Close the session and start a fresh one (context is too polluted) |
| > 90% | Hard close — the agent may be unable to continue |

**Implementation:** `ACPBackend.send()`'s notification drain already processes
`session/update` via `ACPEventTranslator`. Phase 4 adds: capture the
`UsageUpdate` and store it on the `ACPSession` record (or a new
`SessionUsageTracker`). The translator still returns `[]` for `.usageUpdate`
(no AgentEvent — the data is consumed internally, not displayed in the
transcript), but the backend now reads it.

```swift
// In ACPBackend, a new per-session usage tracker:
private struct SessionUsage {
    var used: Int = 0
    var size: Int = 0
    var lastCost: Cost?
}
private var sessionUsage: [String: SessionUsage] = [:]  // key = SessionHandle.id

// In the notification drain (per-turn subscription):
case .usageUpdate(let usage):
    sessionUsage[handle.id] = SessionUsage(
        used: usage.used, size: usage.size, lastCost: usage.cost)
    if usage.size > 0 {
        let ratio = Double(usage.used) / Double(usage.size)
        if ratio > 0.80 {
            // Signal the orchestrator to close + restart this session
        }
    }
```

### Generation gate interaction

The generation gate currently serializes ingest runs on the `.ingest` lane.
Phase 4's parallel executors are **within one ingest run** — they share the
single gate slot already acquired by `run()`. The gate does NOT need to change.
The gate serializes runs across wikis; within a run, the orchestrator manages
concurrency.

However, `stopAgent()` cancels the `for await` consumer. If executors run in a
`withTaskGroup`, cancelling the parent task cancels all child tasks. The
`onTermination` bridge in each `send()` stream calls `cancelSession` for its
own session. This is correct — Stop kills all parallel executors.

### Pool model (if concurrent sessions unsupported)

If the agent doesn't handle concurrent `session/prompt` on one subprocess:

```swift
let poolSize = min(3, executors.count)
var backends: [ACPBackend] = []
for _ in 0..<poolSize {
    backends.append(resolveBackend(policy))
}
// Distribute executors round-robin across the pool
// Each backend runs its executors serially
```

This is more complex (multiple warm processes, multiple drains) and should
only be implemented if concurrent sessions are confirmed unsupported. The
probe test (Phase 4 prerequisite) determines which path to take.

---

## 6. Context-benefit matrix

The core principle: **warm subprocess always; warm sessions only within a
context-beneficial boundary.**

| Boundary | Subprocess | Session | Rationale |
|---|---|---|---|
| Planner reading N sources | Warm (shared) | Warm | Builds cross-source understanding — each source informs the next |
| Executor within 1 source (read → extract → validate → fix) | Warm (shared) | **Warm** | Agent establishes byte offsets, section cross-refs — reconstructing from scratch is expensive |
| Across executors (different sources) | Warm (shared) | **Cold** (or fork) | Independent sources — context carryover is pollution. Parallelizable |
| Executor → Finalizer | Warm (shared) | **Cold** (artifact) | Finalizer reads plan.json + outputs, not the executor's reasoning |
| Finalizer synthesis | Warm (shared) | Warm | Benefits from accumulating plan + outputs as it synthesizes |
| Planner → Executor (fork) | Warm (shared) | Fork | Executor inherits planner's source understanding without reasoning noise |
| Interactive chat (multi-turn) | Warm | Warm | Conversation context is the whole point |
| Interactive chat → new chat | Cold (new process) | Cold (new session) | Different conversation; no context carryover desired |
| Crash recovery | New subprocess | Resume (or load) | Restore the session's context without replaying history |

### The raw-content-ranges nuance

> "We benefit from using warm sessions when storing raw content ranges."

When an agent reads a source and establishes byte offsets, section
cross-references, or content-range references within that source, the
session's accumulated context is **directly beneficial** — the agent can refer
back to what it already read without re-reading. Keeping the session warm
within a single source extraction (read → extract → validate → fix) directly
benefits accuracy and speed.

**Across sources:** cold. Each source is independent; cross-source context is
pollution. An executor for source-2 should NOT carry over source-1's byte
ranges — it would confuse the agent and waste context window.

**Implementation:** within each executor's `send()` call, the agent may issue
multiple tool calls (read the source, read plan.json, write pages, validate).
These all happen within one `session/prompt` call (one turn). If the executor
needs multiple turns (e.g., extract → validate → fix as separate prompts),
keeping the session warm across those turns is the right pattern.

---

## 7. Budget/cost tracking integration (ties to #528)

### The data we're discarding

Two cost data sources are currently ignored:

1. **`UsageUpdate` (per-turn, streamed):** arrives in `session/update`
   notifications carrying `used`, `size`, and `cost: Cost(amount: Double,
   currency: String)` — real dollar cost as the turn progresses.

2. **`Usage` (per-turn, final):** in `SessionPromptResponse.usage` —
   `inputTokens`, `outputTokens`, `cachedReadTokens`, `thoughtTokens`,
   `totalTokens`. Currently `send()` only reads `stopReason`.

### Design: capture and surface both

**Phase 1 addition (low-cost):** In `ACPBackend.send()`, after
`client.sendPrompt` returns successfully, capture the `SessionPromptResponse.usage`:

```swift
let response = try await client.sendPrompt(sessionId:sessionId, content:...)
// Capture usage for budget tracking (#528)
if let usage = response.usage {
    // Store on the session record or emit via a callback
    sessionTurnUsage[handle.id] = TurnUsage(
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cachedReadTokens: usage.cachedReadTokens ?? 0,
        thoughtTokens: usage.thoughtTokens ?? 0,
        totalTokens: usage.totalTokens)
}
```

**UsageUpdate capture (per-notification):** in the notification drain:

```swift
case .usageUpdate(let update):
    sessionUsage[handle.id] = SessionUsage(
        used: update.used, size: update.size, lastCost: update.cost)
```

**Surface to the launcher:** `ACPBackend` already exposes read methods like
`availableModels(for:)` and `processIdentifier(for:)`. Add:

```swift
func turnUsage(for handle: SessionHandle) async -> TurnUsage?
func contextUsage(for handle: SessionHandle) async -> (used: Int, size: Int)?
```

The launcher's `captureAndCacheModels` pattern (a fire-and-forget `Task` after
`backend.start`) is the template: after each phase's stream drains, read the
turn usage and accumulate it into a per-run cost total.

**Queue integration (#528):** the `QueueIngestionProvider.runIngestion`
callback could receive a cost summary. The `QueueItem` could store a
`costEstimate: Double?` for display in the popover. This is out of scope for
the session-efficiency design but the data pipeline (capture → store → surface)
starts here.

### What NOT to do in this design

Don't build the UI display or the queue cost column — that's #528. This design
just ensures the data is captured at the `ACPBackend` seam so #528 can read
it.

---

## 8. Interaction with the generation gate, stopAgent, and the watchdog

### Generation gate

| Scenario | Gate held? | Notes |
|---|---|---|
| One-shot ingest (planner→executor→finalizer) | Yes, `.ingest` lane, held through `finish()` | Unchanged from today. The warm subprocess does not affect gate semantics. |
| Interactive query (multi-turn chat) | Yes, `.interactive` lane, per-turn | Unchanged. The warm process spans turns; the gate serializes generation. |
| Parallel executors (Phase 4) | One slot, shared across all parallel executors | The gate serializes runs across wikis; within a run, the orchestrator manages concurrency. No gate change needed. |
| Crash recovery resume | Gate still held from original run | The `run()` call that acquired the gate is still in-flight; resume happens inside it. |

**Key invariant:** the generation gate serializes **active generation** (a
turn in flight), not process lifetime. A warm subprocess between phases (after
`closeSession`, before the next `start`) does NOT hold the gate any
differently than today — the gate is held for the whole one-shot run by
`finish()` release. The warm process is an implementation detail of the
backend.

### stopAgent()

`stopAgent()` calls `backend.cancel(session)` which does `cancelSession` +
`terminate` + `fireOnExit`. This is correct for all phases:

- **During a phase's `send()` stream:** `onTermination` in the stream's
  continuation cancels the prompt task and sends `cancelSession`. Then
  `stopAgent` calls `cancel()` which terminates the process. The `isRunning`
  guard in the orchestrator's loop prevents the next phase from starting.
- **Between phases (after `closeSession`, before next `start`):** the
  orchestrator checks `isRunning` before each phase. Stop sets
  `isRunning = false` via `finish(-1)`, so the loop exits. The warm process
  is terminated by `cancel()`.
- **During crash recovery (Phase 2):** the `startProcess()` call for the
  new subprocess is a fresh spawn; if Stop fires during it, the same
  `isRunning` guard catches it.

**`closeSession` vs `cancel`:** `closeSession` is the non-destructive
phase-boundary call (keep the process alive). `cancel` is the destructive
teardown (kill the process). `stopAgent` always uses `cancel` — it's the
user saying "stop everything."

### The launcher watchdog (`startCompletionWatchdog`)

The watchdog checks `isRunning` + `lastActivityAt` every 3s. If idle exceeds
180s, it escalates: `stopAgent()` + kill-escalation (SIGTERM → SIGKILL).

With warm subprocess:
- Between phases (after `closeSession`, before the next `start`), there may
  be a brief gap where no events are flowing but the process is alive and
  healthy. This is fine — the gap is < 1s (the orchestrator immediately calls
  the next `start()`). The 180s threshold is generous.
- If `closeSession` itself takes time (network round-trip to the agent), the
  watchdog sees no activity. This is the same as today's `cancel()` gap.
  No change needed.
- Phase 2's crash recovery may look like a stall to the watchdog (the process
  died, `sendPrompt` is suspending). The `TurnLivenessPolicy` (idle timeout
  120s) fires first — it cancels the turn. Then the orchestrator's resume
  flow takes over. The 180s watchdog escalation should be suppressed during
  resume (a flag `isRecovering` on the launcher, checked by the watchdog).

### ACPBackend's per-turn watchdog (`TurnLivenessPolicy`)

The per-turn inactivity watchdog (idle 120s, ceiling 1800s) runs inside
`send()`. It's unaffected by the warm process — it watches for
`session/update` notifications on the active turn. `closeSession` and the
next `createSession` are outside `send()`, so the watchdog is not active
during phase transitions.

---

## 9. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Subprocess death is silent** (issue #338) — `claude-agent-acp` stays alive but sessions break | Medium | High — warm process assumption violated, all subsequent sessions fail | Phase 2 death detection (onExit flag + sendPrompt error + optional health ping). Degrade to fresh subprocess + resume/load/fresh-session. |
| **Concurrent sessions untested** — `session/prompt` on two sessions concurrently may break | Medium | Medium — Phase 4 parallelism may corrupt or deadlock | Probe test before relying on it. Phase 4 falls back to pool model if unsupported. |
| **Context window exhaustion** — warm sessions accumulate context until the agent can't continue | Medium | High — agent produces poor output or errors | Phase 4 context monitoring via `usage_update`. At ~64% proactive artifact write; at ~80% close + fresh session. Context rot starts at ~25% (Chroma 2025) — don't keep sessions warm indefinitely. |
| **`session/close` unsupported by agent** — some agents may not implement it | Low | Low — leaked session memory (not correctness) | Check `sessionCapabilities.close` at init. If unsupported, `closeSession` is a no-op (context freed at process termination). |
| **`session/fork` unsupported** — many agents may not implement fork | Medium | Low — fall back to fresh `session/new` (current behavior, just warm subprocess) | Check `sessionCapabilities.fork` at init. Graceful degradation: fork → fresh session. No context benefit but no correctness risk. |
| **`session/resume` session GC'd** — the agent may have garbage-collected the session by the time we resume | Low | Medium — resume fails, must fall back to load or fresh session | Fallback chain: resume → load → fresh. `session/load` is O(history) but correct. |
| **Prompt cache invalidation on new session** — creating a new `session/new` doesn't inherit API-level prompt cache hits from the prior session | High | Low — marginal cost increase (~5min TTL window for cache hits) | Within the same subprocess, the agent's internal cache may still be warm. Matching system prompt prefixes helps. This is an optimization, not a correctness concern. |
| **Multiple warm processes on different providers** — if stages resolve to different providers, each gets its own warm process | Expected | Low — still fewer subprocess spawns than today (2 instead of 7) | By design. `stageBackendCache` already manages per-provider backends. |
| **`ACPBackend` actor reentrancy** — `closeSession` + `createSession` may interleave if called from different tasks | Low | Medium — session map corruption | The `ACPBackend` actor serializes all access. The `WarmProcess.syncLock` guards session creation/close serialization within a single actor hop. |
| **Orchestrator assumes phases are serial** — Phase 4 parallelism changes the control flow | Expected | Medium — the `for sourceFile in plan.distinctSourceFiles` loop becomes a `withTaskGroup` | Phase 4 is a separate, incremental change. Phase 1–3 keep the serial loop. The parallel refactor is well-contained in `runACPIngestPlannerExecutors`. |

---

## 10. Implementation sequencing

### Dependency graph

```
Phase 1 (warm subprocess) ──────────────────┐
  │                                          │
  ├── Phase 2 (session/resume) ──────────────┤
  │                                          │
  ├── Phase 3 (session/fork) ────────────────┤
  │                                          │
  └── Phase 4 (parallel + context monitor) ──┘
       (depends on Phase 3 for fork-based parallel)
```

### Phase 1: Warm subprocess (ship first — highest impact, lowest risk)

**Why first:** eliminates the most waste (6 subprocess lifecycles), uses only
existing SDK methods (`session/new` + `session/close`), and doesn't change the
serial control flow. The riskiest change is the `ACPBackend` refactor
(separating subprocess lifecycle from session lifecycle), which all later
phases build on.

**Deliverables:**
- `ACPBackend.startProcess()` / `createSession()` internal split
- `ACPBackend.closeSession(_:)` method
- `ACPBackend.cancel()` unchanged (still terminates)
- `runACPIngestPlannerExecutors` uses `closeSession` at phase boundaries, `cancel` at end
- Capability check for `sessionCapabilities.close` at init
- Cost capture: `SessionPromptResponse.usage` read (low-cost addition, sets up #528)

**Estimated overhead saved:** 12–24s per 5-source ingest.

**Test strategy:** unit-test `closeSession` with a fake `Client`; integration
test that `start()` after `closeSession()` reuses the warm process (no new
`launch` call); regression: the existing ingest tests pass unchanged (the
`cancel` → `closeSession` swap is in the orchestrator, not the backend
contract).

### Phase 2: `session/resume` crash recovery (ship second)

**Why second:** builds on Phase 1's separated subprocess/session lifecycle.
Requires capability detection and session-ID persistence. Moderate risk — the
death detection is the hard part.

**Deliverables:**
- `ACPBackend.resume()` implementation (currently returns `nil`)
- Capability detection (`sessionCapabilities.resume`, `loadSession`) at init
- Death detection: `processIsAlive` flag, `sendPrompt` error handling
- Session-ID persistence in `QueueItem` payload (ingest) + chat schema (interactive)
- Orchestrator's `recoverAndResume` flow
- Watchdog: `isRecovering` flag to suppress false stall escalation

**Depends on:** Phase 1.

### Phase 3: `session/fork` for executors (ship third)

**Why third:** builds on Phase 1's warm process + Phase 2's capability
detection. Changes the orchestrator's planner-session lifetime. Lower risk
than Phase 2 (fork is an optimization, not a correctness concern — falls back
to fresh session).

**Deliverables:**
- `ACPBackend.forkSession(from:cwd:)` method
- Capability check for `sessionCapabilities.fork`
- Orchestrator: keep planner session alive through executor loop, fork per
  executor, close planner after
- `systemPromptInjected = true` on forked sessions
- Decision logic: fork if supported, fresh session if not

**Depends on:** Phase 1 (warm process). Independent of Phase 2 but benefits
from its capability detection.

### Phase 4: Parallel executors + context monitoring (ship last)

**Why last:** highest complexity (concurrency control), depends on Phase 3's
fork for the parallel-fork pattern, and requires a probe test for concurrent
session support. Risky enough to be incremental.

**Deliverables:**
- Concurrent session probe test (prerequisite — determines parallel vs. pool)
- `withTaskGroup` parallel executor flow (if concurrent sessions supported)
- Pool model fallback (if not)
- `usage_update` capture in the notification drain
- `ACPBackend.contextUsage(for:)` / `turnUsage(for:)` read methods
- Proactive artifact write at ~64% context usage
- Session close + fresh at ~80%

**Depends on:** Phase 3 (fork). The context monitoring can be implemented
independently of parallelism (it's useful for serial sessions too).

---

## Appendix: SDK method signatures (verified against `wsargent/swift-acp` v0.2.0)

### Client.swift — session lifecycle

```swift
public actor Client {
    // Warm-process lifecycle
    func launch(agentPath: String, arguments: [String], workingDirectory: String?, environment: [String: String]?) async throws
    func initialize(protocolVersion: Int, capabilities: ClientCapabilities, clientInfo: ClientInfo?, timeout: TimeInterval?) async throws -> InitializeResponse
    func authenticate(authMethodId: String, credentials: [String: String]?) async throws -> AuthenticateResponse
    func terminate() async
    func processIdentifier() async -> Int32?
    func processGroupIdentifier() async -> Int32?
    func stderrLines() async -> AsyncStream<String>?

    // Per-session lifecycle
    func newSession(workingDirectory: String, additionalDirectories: [String]?, mcpServers: [MCPServerConfig], timeout: TimeInterval?) async throws -> NewSessionResponse
    func sendPrompt(sessionId: SessionId, content: [ContentBlock]) async throws -> SessionPromptResponse
    func cancelSession(sessionId: SessionId) async throws
    func setModel(sessionId: SessionId, modelId: String) async throws -> SetModelResponse

    // Phase 2: crash recovery
    func resumeSession(sessionId: SessionId, cwd: String, additionalDirectories: [String]?, mcpServers: [MCPServerConfig]) async throws -> ResumeSessionResponse
    func loadSession(sessionId: SessionId, cwd: String, additionalDirectories: [String]?, mcpServers: [MCPServerConfig]) async throws -> LoadSessionResponse

    // Phase 3: fork
    func forkSession(sessionId: SessionId, cwd: String, additionalDirectories: [String]?, mcpServers: [MCPServerConfig]) async throws -> ForkSessionResponse

    // Phase 1: close without terminate
    func closeSession(sessionId: SessionId) async throws -> CloseSessionResponse

    // Utility
    func listSessions(cwd: String?, cursor: String?, timeout: TimeInterval?) async throws -> ListSessionsResponse
    func deleteSession(sessionId: SessionId) async throws -> DeleteSessionResponse

    // Notification stream (single consumer — fanned out via NotificationFanout)
    var notifications: AsyncStream<JSONRPCNotification> { get }
}
```

### Response types

```swift
// SessionPromptResponse — carries stopReason + Usage (Phase 1/#528 cost capture)
struct SessionPromptResponse {
    let stopReason: StopReason   // .endTurn, .maxTokens, .refusal, .cancelled, .maxTurnRequests
    let usage: Usage?            // inputTokens, outputTokens, cachedReadTokens, thoughtTokens, totalTokens
}

// ForkSessionResponse — carries the NEW session id (Phase 3)
struct ForkSessionResponse {
    let sessionId: SessionId     // the forked session's id (distinct from the parent's)
    let modes: ModesInfo?
    let configOptions: [SessionConfigOption]?
}

// UsageUpdate — streamed via session/update (Phase 4 context monitoring)
struct UsageUpdate {
    let used: Int                // tokens consumed
    let size: Int                // total context window
    let cost: Cost?              // Cost(amount: Double, currency: String)
}

// InitializeResponse — carries agentCapabilities for capability detection (all phases)
struct InitializeResponse {
    let protocolVersion: Int
    let agentInfo: AgentInfo?
    let agentCapabilities: AgentCapabilities  // has sessionCapabilities?.resume/fork/close/list
    let authMethods: [AuthMethod]?
}
```

### Capability check cheat sheet

```swift
let caps = initResponse.agentCapabilities
let sessionCaps = caps.sessionCapabilities

let canClose  = sessionCaps?.close != nil       // Phase 1
let canResume = sessionCaps?.resume != nil      // Phase 2
let canLoad   = caps.loadSession == true       // Phase 2 fallback
let canFork   = sessionCaps?.fork != nil        // Phase 3
let canList   = sessionCaps?.list != nil        // Phase 2 death detection (optional)
```
