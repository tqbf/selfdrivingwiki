# ACP backend spike — findings

**Status:** Spike COMPLETE. `swift-acp` integrates and compiles; `ACPBackend` +
permission policy implemented + unit-tested (no live agent). Not wired into the
launcher/UI yet (next slice).

## Headline: does `swift-acp` compile under Swift 6.0 / macOS 15?

**YES.** The whole `ACP` + `ACPModel` product builds with zero warnings/errors
under Swift 6.0 strict concurrency (the SDK is `swift-tools-version: 5.9`, so it
builds in Swift 5 language mode; the consuming app target `WikiFS` builds in
Swift 6 strict-concurrency mode and the SDK's types are `Sendable`/actor-based).

### Version caveat (important)

The README says `from: "1.0.0"`, but **no `1.0.0` tag exists** — the only
published tag is **`v0.1.0`** (24 commits, community/early). `from: "1.0.0"`
fails to resolve:

```
error: Dependencies could not be resolved because no versions of 'swift-acp'
match the requirement 1.0.0..<2.0.0
```

Pinned to **`from: "0.1.0"`** instead. If a real `1.0.0` ships later, bump it.
`Package.swift` documents this in the dependency comment.

## API surface (what we used)

The SDK matches the README. Key types (`import ACP` / `import ACPModel`):

- `Client` — an `actor`. `launch(agentPath:arguments:workingDirectory:)`,
  `initialize(protocolVersion:capabilities:clientInfo:timeout:)`,
  `newSession(workingDirectory:)` → `NewSessionResponse` (`.sessionId`),
  `sendPrompt(sessionId:content:)` → `SessionPromptResponse` (`.stopReason`),
  `setDelegate(_:)`, `notifications: AsyncStream<JSONRPCNotification>` (actor-
  isolated computed property — `await` it once, then iterate),
  `cancelSession(sessionId:)`, `terminate()`.
- `ClientDelegate` (protocol, `AnyObject` + `Sendable`) — the permission seam is
  `handlePermissionRequest(request:) async throws -> RequestPermissionResponse`.
  Also requires fs read/write + terminal methods (this spike stubs those as
  `throw ClientError.invalidResponse`).
- `SessionUpdate` (enum) — `agentMessageChunk`/`agentThoughtChunk`/
  `userMessageChunk` (carry a `ContentBlock`), `toolCall` (`ToolCallUpdate`),
  `toolCallUpdate` (`ToolCallUpdateDetails`), `plan*`, `usageUpdate`,
  `currentModeUpdate`, etc.
- `SessionPromptResponse.stopReason: StopReason` — `.endTurn`/`.maxTokens`/
  `.refusal`/`.cancelled`/`.maxTurnRequests`. **All** are turn boundaries.
- `RequestPermissionRequest` (`options: [PermissionOption]`, `toolCall`,
  `sessionId`) → `RequestPermissionResponse(outcome: PermissionOutcome)`.
  `PermissionOutcome(optionId:)` = "selected"; `PermissionOutcome(cancelled:)`
  = "cancelled".

### One non-obvious bit

`sendPrompt` is `async throws` and **blocks until the whole turn completes**
(returns `SessionPromptResponse`). So `ACPBackend.send` must NOT await it
inline (that would deadlock: notifications can't be delivered until the consumer
drains, and the consumer can't drain until `send` returns the stream). The
backend runs `sendPrompt` in a detached `Task` while concurrently draining
`client.notifications` for `session/update`s.

## What was implemented

`Sources/WikiFS/ACPBackend.swift` + `Sources/WikiFS/ACPPermissions.swift`,
`ACPBackend: AgentBackend` (actor-backed, Sendable, strict-concurrency-safe):

### ACP → AgentEvent mapping (`ACPEventTranslator`, pure, I/O-free)

| ACP `SessionUpdate`                    | `AgentEvent`                              |
|----------------------------------------|-------------------------------------------|
| `agentMessageChunk(.text)`             | `.assistantTextDelta` (launcher coalesces)|
| `agentThoughtChunk(.text)`             | `.raw` (no dedicated case; surfaced)      |
| `userMessageChunk`                     | (dropped — echoes the user's own turn)    |
| `toolCall`                             | `.toolUse` (name from title/kind, path)   |
| `toolCallUpdate` (completed/failed+out)| `.toolResult(isError:)`                    |
| `plan*`, `usageUpdate`, `currentMode…` | (nothing — not rendered)                  |

### Turn-end / `.messageStop` synthesis

ACP has **no turn-end notification** — the turn ends when `session/prompt`
*returns* (carrying `stopReason`). `ACPBackend.send` synthesizes `.messageStop`
on prompt completion (any `stopReason` → `.messageStop`), satisfying the port's
turn-boundary contract (`AgentEvent.endsGeneration(.messageStop) == true`).
On error it emits `.raw` + `.messageStop`. Mirrors how `ClaudeCLIBackend` keys
turn end off the `message_stop` wire line.

### Permission policy (`PermissionPolicy` + `ACPPermissionDelegate`)

- **yolo** → `handlePermissionRequest` resolves immediately with the request's
  allow option (`allow_always` preferred over `allow_once`). Default.
- **alwaysAsk** → suspends (records a pending request with a
  `CheckedContinuation`) and **blocks** until the future UI calls
  `ACPBackend.resolvePermission(sessionHandle:optionId:)`. The resolver seam is
  unit-tested, not yet wired to UI. Mirrors paseo's `pendingPermissions` map.

State is held behind `OSAllocatedUnfairLock` (`ACPPermissionDelegate` is a
`final class`, `@unchecked Sendable` — the lock is the synchronization).

## Tests (`Tests/WikiFSTests/ACPBackendTests.swift`, Swift Testing, 17 tests)

**All pass.** No live subprocess. Covers:
- Translator: text chunk → `.assistantTextDelta`; thought → `.raw`; tool call →
  `.toolUse`; completed/failed tool → `.toolResult`; pending → nothing;
  unmodeled → nothing.
- Turn-boundary contract: `.messageStop` ends generation; translator never emits
  it (synthesized at prompt completion).
- Permission policy: yolo auto-allows (prefers `allow_always`); no-allow →
  cancelled; alwaysAsk defers (pending recorded) → `resolve(allow)` → allow,
  `resolve(deny)` → deny; unknown option → no-op.

## Stubs / caveats

- **Agent path config:** read from `BackendProfile.providerHints["acpAgentPath"]`
  (fallback `model`) + `["acpAgentArgs"]` (comma-separated). Not hardcoded to the
  Zed adapter — any ACP agent. Not wired to `AgentCommandConfig` yet.
- **Auth:** not implemented (`initialize`'s `authMethods` ignored). A later slice.
- **fs/terminal delegate methods:** throw `.invalidResponse` (spike only
  exercises the permission seam). A future slice wires these to perform/gate
  file writes + terminal commands (the second structural gate).
- **onExit:** bound in `start`, fired from `cancel`. The SDK `Client` has no
  direct termination handler exposed; a future slice adds process-exit detection.
- **"agent emits no request_permission" caveat:** always-ask enforcement
  *depends on the agent emitting `session/request_permission` for writes*. Most
  do (Claude via the wrapper, Copilot, …), but not all — so **yolo is the safe
  default**. This matches the design doc's caveat and paseo's smoke-test note
  ("wrapper emitted no requestPermission" is a *failure* mode there).

## Verify

```
swift build                                  # ✓ Build complete (whole package)
swift test --filter ACPBackendTests          # ✓ 17/17 passed
```

## Next slice

2. Wire-in + UI: select ACP vs CLI backend; per-chat always-ask/yolo toggle
   (default yolo); the Approve/Reject affordance fed by the pending permission
   → `ACPBackend.resolvePermission`.
3. Provider generalization (#217): provider/agent picker + auth UI.
