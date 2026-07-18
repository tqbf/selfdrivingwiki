## ACP session efficiency Phase 3: `session/fork` for executors

Implements Phase 3 of `plans/acp-session-efficiency.md` (issue #525).

### What

After the planner produces `plan.json`, each executor **forks** the planner's session — inheriting the planner's understanding of the source layout without the reasoning noise (intermediate tool calls, failed attempts). If the agent doesn't support `session/fork`, falls back to fresh `session/new` per executor (current behavior).

### Changes

**`ACPBackend.swift`:**
- Added `canForkSession: Bool` to the `WarmProcess` struct, captured from `agentCapabilities.sessionCapabilities?.fork` at `startProcess()` time
- Added `forkSession(from:cwd:)` method:
  - Guards on `canForkSession` and parent session existence
  - Calls `client.forkSession(sessionId:cwd:)` (SDK method from `swift-acp` v0.2.0)
  - Creates a new `ACPSession` record with `systemPromptInjected = true` (fork inherits parent's already-injected system prompt)
  - Returns `nil` if fork is unsupported — caller falls back to `createSession()`

**`AgentLauncher.swift`:**
- Added `plannerSessionHandle` field to track the planner session across the executor phase
- `runACPIngestPlannerExecutors` flow updated:
  1. Planner: `start()` -> `send()` -> **keep session alive** (was: close immediately)
  2. Executors: `forkSession(from: plannerSession)` -> `send()` -> `closeSession()` per source. If fork returns nil, falls back to `start()` (fresh session)
  3. After all executors: `closeSession(plannerSession)` — the planner session has served its purpose as fork source
  4. Finalizer: unchanged (`start()` -> `send()` -> `closeSession()`)
  5. End: `cancel()` all warm subprocesses
- `runPhase` gained a `forkFrom: SessionHandle?` parameter (default nil = fresh session)
- `stopAgent()` and `finish()` clear `plannerSessionHandle` to prevent dangling references

### Design rationale

From the context-benefit matrix in the design doc:
- **Executor reading 1 source**: the planner's understanding of the source layout IS beneficial context, but the planner's reasoning about what to do IS noise
- `session/fork` solves this: the forked executor starts with a copy of the planner's conversation context but diverges from that point
- Claude Code's SDK supports fork: it creates a new session that starts with a copy of the original's history

### Graceful degradation

| Capability | Behavior |
|---|---|
| `sessionCapabilities.fork` supported | `forkSession()` -> executor inherits planner context |
| `sessionCapabilities.fork` NOT supported | `forkSession()` returns `nil` -> `runPhase` falls back to `backend.start()` (fresh session, current behavior) |

No correctness risk — fork is an optimization, not a requirement.

### Testing

- `swift build` passes
- Fast test tier (2456 tests) passes
- Fork requires a live agent subprocess to exercise end-to-end; the capability detection + fallback logic is the testable unit
