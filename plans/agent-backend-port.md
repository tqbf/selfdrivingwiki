# Agent backend port (Phase 0) — decouple the conversation layer from the agent wire protocol

## Why

The conversation-ui plan (`conversation-ui.md`) Phase B/D3/D5 is contorting
around Claude-CLI-specific semantics: capture `session_id` from `system/init`,
`--resume`, and `agent_executable` matching. A coupling audit (`general-purpose:
agent-coupling-audit`) found the Claude stream-json knowledge confined to **four
isolated units**, and that `AgentEvent` is already a clean, rendering-oriented
internal model that UI and persistence depend on. `--resume`/`session_id` was
**never built** — so there is no migration tax; we adopt whatever session model
we choose on a green field.

**Goal:** introduce an `AgentBackend` port so the UI, persistence, and
conversation management depend only on `AgentEvent` + the port — never on a wire
format. The backend (Claude CLI today; ACP or Polytoken later) becomes a
swappable implementation behind the port. This **defers the ACP-vs-Polytoken-
vs-CLI decision** and makes a future backend swap transparent to this branch: a
new backend is a new file conforming to `AgentBackend` + a factory entry; it
does not touch `AgentTranscriptWebView`, `WikiStoreModel`, `ChatModels`, the
launcher's gates/locks, or `ConversationView`.

**Phase 0 is behavior-preserving:** extract the port, move today's Claude CLI
behind `ClaudeCLIBackend`, prove existing tests stay green. No schema change,
no UI change, no resume. It is the gate that unblocks the rest of the
conversation-ui work without committing to a backend.

> See `plans/conversation-ui.md` for the upstream plan this reframes, and the
> ACP/Polytoken research summaries in this session's history for the backend
> comparison that motivated deferring the choice.

## Current state (verified)

- Protocol knowledge is confined to: `OperationCommand.build`/`buildInteractiveQuery`
  (`Sources/WikiFSCore/OperationCommand.swift:88`,`:150`), `AgentEventParser`
  (`Sources/WikiFSCore/AgentEvent.swift:138` + decode structs `:253`+),
  `AgentLauncher.streamJSONLine` (`Sources/WikiFS/AgentLauncher.swift:1310`),
  and `IngestPlan.agentsJSON` (`Sources/WikiFSCore/IngestPlan.swift:66`, consumed
  at `OperationCommand.swift:127` as `--agents`).
- `AgentEvent` (`Sources/WikiFSCore/AgentEvent.swift:15`) is `Codable` with
  **synthesized** conformance (no custom enum coder); it carries human-readable
  strings, not raw protocol blobs. It is persisted as `chat_messages.event_json`
  via plain `JSONEncoder/Decoder` (`SQLiteWikiStore.swift:4033,4100`). A
  different parser can populate it unchanged; adding cases is additive and
  backward-compatible for existing rows.
- `AgentLauncher` is `@MainActor @Observable` (`AgentLauncher.swift:20`); process
  I/O already happens off-main via `readabilityHandler` → `Task { @MainActor in
  … }` hops (`:678-688`,`:893-901`). Moving decode off-main is strictly better,
  not a new hazard.
- The one leak: per-turn boundary detection — `AgentEvent.endsGeneration`
  (`AgentEvent.swift:113-117`, true for `.result`/`.messageStop`) drives the
  generation gate, edit lock, and transcript flush at `AgentLauncher.swift:1151`.
  `.messageStop` is synthesized only from Claude's `message_stop` wire line
  (`AgentEvent.swift:183-184`).

## The port

```swift
/// Backend-agnostic agent contract. UI, persistence, and conversation
/// management depend only on this + `AgentEvent` — never a wire format.
public protocol AgentBackend: Sendable {
    /// Start a fresh session. `onExit` fires exactly once when the underlying
    /// process/agent terminates, carrying its exit status — the completion
    /// channel the launcher's watchdog reconciles against (replaces direct
    /// `Process` introspection).
    func start(profile: BackendProfile,
               systemPrompt: String,
               onExit: @escaping @Sendable (Int) -> Void) async throws -> SessionHandle

    /// Send one user turn. Returns the streamed events for THIS turn; the
    /// stream finishes at the turn boundary (`.messageStop`). The session
    /// (e.g. the CLI `Process`) persists across turns via `SessionHandle`.
    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent>

    /// Continue a prior session by its opaque id. nil if this backend cannot
    /// resume (id unknown / GC'd / unsupported). Whether the model can change
    /// on resume is a backend capability — see "Model switching" below.
    func resume(sessionID: String,
                profile: BackendProfile) async throws -> SessionHandle?

    /// Stop the session and release resources. Idempotent.
    func cancel(_ session: SessionHandle) async
}

/// Abstract per-mode/per-op configuration; each backend interprets it.
/// CLI: resolved executable + env + wikictl dir + sandbox. Polytoken: facet +
/// model. ACP: agent config + MCP servers. The launcher resolves app-level
/// concerns (scratch dir, sandbox, bundled helpers) and passes them in here.
public struct BackendProfile: Sendable {
    public var model: String?
    public var providerHints: [String: String]   // backend-specific
    public var scratchDirectory: URL?
    public var isReadOnly: Bool                   // gates Write/Edit tools
}

/// Opaque, backend-neutral session token. Persisted on the chat row as
/// `session_id` (+ `backend_kind`) so a future continue targets the right
/// backend. Does NOT wrap `Process` (which is not Sendable).
public struct SessionHandle: Sendable, Hashable {
    public let id: String          // opaque; backend-defined
}

public struct TurnInput: Sendable {
    public var userText: String
}
```

- **`AgentEvent` stays the stable contract.** Each backend's parser maps its
  wire events onto it. It grows *additively* (new cases) without breaking
  existing persisted rows — so a richer backend (e.g. Polytoken's `DaemonEvent`
  `model_switch`/`interrogative`) is surfaced later by extending `AgentEvent`,
  not by changing the contract.
- **`BackendProfile` is abstract.** The launcher resolves app-level concerns
  (scratch dir, sandbox seatbelt, bundled `wikictl` path, log layout) and passes
  them in; the backend interprets the rest (executable/env for CLI, facet for
  Polytoken, agent config for ACP). Per-mode Ask/Edit profiles (conversation-ui
  D5) become `BackendProfile` values.
- **`SessionHandle` is an opaque `Sendable` token** — never exposes `Process`.
  The chat row stores `session_id` + `backend_kind` so an id from one backend is
  never fed to another (the D3 "executable match" concern, generalized and
  backend-neutral).

## Concurrency shape (validated against `swift-concurrency-pro`)

- **`ClaudeCLIBackend` is an `actor`** (holds `Process` + per-session state;
  `Process` is not `Sendable`). **No `@unchecked Sendable`** — use the actor /
  value types / region-based isolation. `SessionHandle` is a value type.
- **Per-turn `AsyncStream`** via `AsyncStream.makeStream(of: AgentEvent.self)`
  (the factory returns stream + continuation as a tuple — no closure capture).
  The `readabilityHandler` captures the **`Sendable`** continuation, decodes
  off-main, and `yield`s. Decode moving off-main is strictly better than today
  (today it hops to main first).
- **`mergeOrAppend` stays in the launcher.** Delta-coalescing is transcript UI
  state (`events` array + `isStreamingAssistantRow`), not wire format. The
  backend yields raw `.assistantTextDelta`/`.assistantText`; the launcher
  coalesces. (Moving it into the backend would split transcript state across the
  actor boundary and make the backend aware of rendering rules.)
- **Continuation lifecycle — finish exactly once:**
  - process `terminationHandler` → `finish()` the current turn's continuation
    exactly once + fire `onExit(status)`.
  - `continuation.onTermination = { reason in … }` — check the reason:
    `.cancelled` → tear down the session (`process.terminate()`); `.finished` →
    no-op (natural turn end; the `Process` stays alive for the next turn). This
    is the cancellation bridge: the launcher cancels its `for await` task →
    stream terminates → `onTermination(.cancelled)` → process killed.
- **Buffering:** `.unbounded` — the `@MainActor` consumer drains promptly, and
  tokens must never be dropped (dropping deltas corrupts the transcript). Do not
  use `bufferingNewest`.
- **Actor isolation unchanged:** backend off-main, launcher `@MainActor`. The
  existing turn-boundary flush discipline (writes flow through the main-actor
  model; `WikiReadPool` for off-main reads) carries over — see
  `docs/skills/sqlite-concurrency/SKILL.md`.

## The boundary (move / stay) — file:line grounded

### Moves into `ClaudeCLIBackend`
| Current location | Becomes |
| --- | --- |
| `OperationCommand.build` (`OperationCommand.swift:88`) + `buildInteractiveQuery` (`:150`) | backend's command assembly (the flag surface: `--output-format stream-json`, `--input-format stream-json`, `--include-partial-messages`, `--append-system-prompt`, `--allowed-tools`, `--disallowed-tools`, `--model`, `-p`, `--agents`). `OperationCommand` stays as the backend's internal pure value type. |
| `AgentEventParser.parse` (`AgentEvent.swift:138`) + `Envelope`/`ContentBlock`/`StreamEvent` decode | backend's private line→`AgentEvent` decode |
| `streamJSONLine(forUserText:)` (`AgentLauncher.swift:1310`) + stdin write (`:964`,`:988`) | backend's `TurnInput`→NDJSON encoder (owns stdin) |
| `Process` spawn + pipes + `readabilityHandler`/`terminationHandler` (`:664-725`,`:880-945`) | backend process management → bridges to `AsyncStream` |
| `--agents` / `IngestPlan.agentsJSON` (`IngestPlan.swift:66`) | backend-internal (only the CLI backend knows `--agents` exists) |
| `PathPreflight`/`resolveClaude` (`:133`,`:595`,`:798`) | backend-internal (the launcher must not know the binary is named "claude") |

### Stays in `AgentLauncher`
- `events: [AgentEvent]` (`:30`), `rawTranscript`/`stderr`/`extractionLog`
  (`:37,43,44`).
- Generation gate: `generationGate` (`:304`), `holdsGenerationSlot` (`:315`),
  `awaitGenerationSlot()` (`:335`), `releaseGenerationSlot()` (`:345`),
  `isGenerating` (`:94`)/`setGenerating` (`:215`).
- Edit lock: `onUnlockHandler` (`:149`), `onTurnBoundaryHandler` (`:162`),
  `releaseEditLock()` (`:1274`).
- Transcript flush/sink: `transcriptSink` (`:170`), `persistedEventCount`
  (`:174`), `flushTranscript()` (`:1121`), `unflushedTail` (`:1111`).
- Persistence coordination (`onTranscript` plumbing, `appendChatEvents`).
- Cancellation: `stop()`/`stopAgent()`/`stopExtraction()` (`:1029,1055,1075`) →
  "ask the backend to cancel + tear down launcher state."
- Lifecycle flags: `isRunning`, `isInteractiveSession`, `runningKind`,
  `exitStatus`, `preflightError`, `logFileURL`, `runStartedAt`, `lastActivityAt`.
- App-level concerns: scratch-dir creation (`makeScratchDirectory` `:1362`), log
  files, sandbox resolution (`resolveSandboxInvocation` `:1399`),
  `resolvePdf2mdScriptPath` — passed into `BackendProfile`.
- **`mergeOrAppend` (`:1180-1207`) stays** (transcript coalescing is UI state).

## Turn-boundary contract (the one leak, closed)

Keep the `.messageStop` **case** and `endsGeneration` logic byte-identical;
promote `.messageStop` to a **backend-synthesized turn-boundary marker** — every
`AgentBackend` impl MUST yield `.messageStop` at each turn end (documented as a
protocol contract). `ClaudeCLIBackend` gets it free from the wire; a future
direct-API backend synthesizes it on per-turn stream completion.

- **Codable-safe (zero migration):** `AgentEvent` uses synthesized Codable (JSON
  tag = case name), and `.messageStop` is `isPersistable == false`
  (`ChatModels.swift:88`) so it is never written to `event_json` anyway. Keep the
  case name unchanged.
- Redocument `endsGeneration` as the "turn boundary" predicate (intent), not
  "Claude said `message_stop`." The logic at `AgentLauncher.swift:1151` stays
  byte-identical.
- **Risk:** the generation gate, edit lock, and transcript flush all key off
  this. A backend that fails to synthesize `.messageStop` strands the edit lock
  and the spinner. Enforced by contract + a turn-boundary test (every backend's
  test fixture must show a `.messageStop` between turns).

## Two design decisions (resolved; flagged for review)

1. **Completion channel.** Today `startCompletionWatchdog` (`:734`) polls
   `process?.isRunning`/`.terminationStatus` directly — impossible once `Process`
   moves behind the port. **Resolved:** the backend drives completion via the
   per-turn `AsyncStream` finishing **plus** an `onExit(status:)` callback fired
   exactly once from `terminationHandler`. The watchdog becomes a
   timeout-reconciler against `onExit`, not a liveness-poller. No raw `Process`
   access remains in the launcher. *(Alt, rejected: expose liveness/exit on
   `SessionHandle` and keep polling — reintroduces `Process` coupling.)*
2. **Raw-transcript logging.** `run.jsonl`/`run.stderr.log` are written from raw
   bytes in `ingestStdout` (`:1134-1135`). **Resolved (lean):** the backend owns
   raw-bytes logging (it has the bytes); the launcher keeps its `rawTranscript`
   mirror via a raw-chunk side-channel, or drops the mirror. Minor behavior
   delta either way — decide during implementation.

## Model switching is a backend capability (D3 correction)

The conversation-ui plan D3 assumed "`--resume` (model may differ; the CLI
accepts a model switch on resume)." **It does not.** Per Claude Code docs,
resumed sessions *keep the model they were using when the transcript was saved,
regardless of the current model setting* (by design — prevents one session's
`/model` choice from bleeding into another on resume). A fresh spawn can set
`--model`; `--resume` ignores it and pins to the saved model. (Interactive
`/model` changes the *live* session, but our app drives stream-json, so model is
fixed per spawn.)

Consequences, per backend:
- **Claude CLI:** cannot switch models when continuing a conversation — resume
  pins to the saved model. To use a different model you must start a fresh
  session (the seeded-fallback path), losing resume.
- **Polytoken:** yes, between turns — `POST /model` (409 `ModelConflictResponse`
  if mid-generation).
- **ACP:** uneven — model selection is not standardized (issue #182);
  agent-dependent.
- **App data model:** already supports per-turn model variation — model is
  recorded per turn in `.systemInit(model:)` (`event_json`), so a conversation
  can span models at the data layer regardless of backend.

**Therefore model-switching is a backend capability, not a given.** The port
surfaces it conditionally (a backend declares whether `resume` can change the
model); the UI/persistence model per-turn models via `.systemInit`. A "continue"
uses the mode's *current* profile; whether the model actually changes depends on
the backend. D3 must not assume a model switch on resume.

## Phase 0 steps + gate

1. Define `AgentBackend`/`BackendProfile`/`SessionHandle`/`TurnInput` in
   `Sources/WikiFS/AgentBackend.swift`.
2. Build `ClaudeCLIBackend` (actor) in `Sources/WikiFS/ClaudeCLIBackend.swift`,
   wrapping today's spawn/parse/encode **verbatim** (`OperationCommand` +
   `AgentEventParser` + `streamJSONLine` + `Process` + `readabilityHandler`s +
   `PathPreflight` + `--agents`). Bridge pipe callbacks → per-turn `AsyncStream`.
3. Rewire `AgentLauncher` to hold an `AgentBackend` + `SessionHandle` and consume
   the per-turn `AsyncStream` (`mergeOrAppend` → `endsGeneration` → gate/lock/
   flush). Resolve the watchdog via `onExit`.
4. Redocument `endsGeneration` as turn-boundary; **no `AgentEvent` code change.**

**Gate (behavior-preserving):** existing launcher/parser tests green
(`AgentEventParserTests`, `AgentEventCodableTests`, `ChatPersistenceLauncherTests`,
`ChatStoreTests`, etc.); a streamed session renders identically through
`AgentTranscriptWebView`; the edit lock releases at turn boundaries; `stopAgent`
cancels cleanly. No schema change, no UI change, no resume.

**Sequence:** define the port → build `ClaudeCLIBackend` wrapping current code
verbatim → rewire the launcher to consume the stream → resolve the watchdog
last.

## Reframed conversation-ui slices (against the abstract backend)

| Slice | Before | After (backend-agnostic) |
| --- | --- | --- |
| **Phase B (session identity)** | `claude_session_id` + `--resume` hack | opaque `session_id` + `backend_kind` on `chats` (backend-neutral); resume = `backend.resume(sessionID:)`. No Claude-specific column; no `--resume`+stream-json risk. Default backend may stub resume. |
| **D3 (continue)** | `--resume` or seeded fallback | `backend.resume(sessionID:)` or seeded fallback — backend-blind. Model-switch is a backend capability (see above), not an assumption. |
| **D5 (profiles)** | flat `AgentCommandConfig` | `BackendProfile` (abstract); `AgentCommandConfig` profiles → `BackendProfile`; per-backend mapping. |
| **A / D2 / D4** | as planned | unchanged — backend-agnostic |

## What stays deferred

- **The actual backend swap** (a `PolytokenBackend` or `ACPBackend` behind the
  port) — a new impl + factory entry; transparent to this branch's UI/
  persistence/conversation code.
- **The wiki-tools MCP server.** The CLI backend keeps `wikictl` via the shell
  tool (no MCP). An ACP backend (MCP-centric) or a refined Polytoken backend
  would ship a small MCP server exposing wiki-store tools.
- **Resume actually working end-to-end.** Phase B wires the contract + opaque
  columns; the default backend's resume implementation is separate (and may stub
  until a backend that supports it is chosen).
- **Multiple concurrent live sessions per kind** (needs a per-conversation
  launcher/backend pool).
- **`[[chat:…]]` wikilinks, quote anchors, `chats.jsonl`, File Provider `chats/`
  tree** (unchanged from conversation-ui phase 1 deferrals).

## Files touched (Phase 0)

| Area | File | Change |
| --- | --- | --- |
| App | `Sources/WikiFS/AgentBackend.swift` (new) | `protocol AgentBackend` + `BackendProfile` + `SessionHandle` + `TurnInput` |
| App | `Sources/WikiFS/ClaudeCLIBackend.swift` (new) | actor wrapping today's spawn/parse/encode verbatim; pipe→`AsyncStream` bridge |
| App | `Sources/WikiFS/AgentLauncher.swift` | hold `AgentBackend` + `SessionHandle`; consume per-turn `AsyncStream`; watchdog via `onExit` |
| Core | `Sources/WikiFSCore/AgentEvent.swift` | no code change (redocument `endsGeneration` as turn-boundary) |
| Core | `Sources/WikiFSCore/OperationCommand.swift` | unchanged (becomes `ClaudeCLIBackend` internal; may relocate to `WikiFS` later) |
| Core | `Sources/WikiFSCore/IngestPlan.swift` | unchanged (subagent config flows through `WikiOperation`) |
| App | `Sources/WikiFS/AgentOperationRunner.swift` | likely unchanged (talks to the launcher, not the backend) |
| Tests | extensions to launcher/parser tests | port parity; turn-boundary contract; `onExit`; cancellation |

## Risks

1. **Turn-boundary contract violation** strands the edit lock / spinner. Mitigated
   by the documented contract + a per-backend fixture asserting `.messageStop`
   between turns. (`endsGeneration`/`.messageStop` is filtered from persistence
   and rendering, so blast radius is control logic only.)
2. **Watchdog completion channel** — verify no liveness-polling of `Process`
   remains after extraction; `onExit` must fire exactly once on every exit path
   (clean, crash, cancel).
3. **`AsyncStream` continuation lifecycle** — finish exactly once; `onTermination`
   must distinguish `.cancelled` (tear down session) from `.finished` (natural
   turn end, keep `Process`). A bug here either hangs the consumer or kills the
   session between turns.
4. **Parse relocating off-main** — strictly better, but verify the parser is pure
   (no main-actor assumptions). The audit confirms it is (`Envelope`/decode
   structs are value types; `JSONValue`/`ToolInputSummary`/`StringOrBlocks` are
   parser-internal helpers that never escape).
5. **`interactiveSendTask` gate-acquire-then-write ordering** (`:973-995`) — after
   extraction the launcher acquires the gate, then `await backend.send(...)`; the
   write moves into the backend. Preserve the `isAwaitingGenerationSlot` ↔ send
   ordering and the cancellation path (`interactiveSendTask?.cancel()`).
