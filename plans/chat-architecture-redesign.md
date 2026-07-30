# Chat Architecture Redesign

Last updated: July 30, 2026

## Status

Issue: #982

State: In progress

Scope of this branch: Phase 0, Phase 1, Phase 2, and Phase 3

This document is the design record for the chat redesign. The goal is to move
chat to a daemon-owned, typed conversation domain with explicit turn
submission, queuing, lifecycle, permissions, cancellation, recovery,
persistence, and client synchronization.

This branch implements the Phase 0/1 foundation, the Phase 2 persistence
rebuild, and the Phase 3 per-chat daemon-controller move. It does not
implement the Phase 4 XPC wire redesign, the Phase 4 client sync replacement,
or the Phase 5 UI decomposition.

Remediation note for PR #990 on Thursday, July 30, 2026:

- the exact-head corrective audit at
  `e1a5cf259e859c2680282f7c5e1bfc8c1ddbfcb6` found regressions in transcript
  persistence, live delta forwarding, bounded resume fallback, shared
  generation-gate wiring, preflight rollback/propagation, queue draining,
  `chatSessionState` purity, summarization callbacks, provider-session
  sequencing, compatibility `chat_messages` dual-writes in the real daemon ACP
  path, and API-manifest/documentation coverage
- the corrective pass on `chat-redesign-phase3` repairs those Phase 3 daemon /
  runtime / controller / store contracts without taking the out-of-scope Phase
  4 wire or Phase 5 UI decomposition work
- the repaired Phase 3 invariant is now explicit: for streamed assistant output
  in the daemon path, typed controller persistence is the sole compatibility
  `chat_messages` writer; the launcher-era streaming checkpoint sink stays
  disabled in this path
- the current exact-head evidence is recorded in
  [`progress/2026-07-29T201105Z-chat-redesign-phase3-982.md`](../progress/2026-07-29T201105Z-chat-redesign-phase3-982.md)

## Problem

The current design has good parts, but they came from separate fixes. The
result is a split authority model:

- [`Sources/WikiFS/Chats/ChatDetailView.swift`](../Sources/WikiFS/Chats/ChatDetailView.swift)
  still owns queued-turn delivery, live-versus-persisted source selection,
  permission interpretation, and start-versus-continue routing.
- [`Sources/WikiFS/Chats/RemoteChatSession.swift`](../Sources/WikiFS/Chats/RemoteChatSession.swift)
  mirrors a large launcher-shaped surface and rebuilds old booleans from daemon
  state.
- [`Sources/WikiFSEngine/ChatXPCRequests.swift`](../Sources/WikiFSEngine/ChatXPCRequests.swift)
  sends flat session state and permission strings instead of a typed
  conversation model.
- [`Sources/wikid/DaemonChatHost.swift`](../Sources/wikid/DaemonChatHost.swift)
  still owns launcher-shaped orchestration, polling, and cross-turn decisions.

These layers duplicate lifecycle facts in different shapes. That makes stale
state, missed updates, and queue-delivery bugs easy to ship and hard to test.

## Current failure modes

The current chat stack has these structural problems:

1. `ChatDetailView` decides when to fire queued work by observing launcher-era
   booleans. View lifetime and queue lifetime are coupled.
2. The app chooses between live transcript arrays and persisted rows with local
   heuristics instead of a typed projection contract.
3. Permission requests cross the daemon boundary as JSON fragments, then get
   parsed again in the app.
4. The daemon and the app both infer lifecycle from mixed booleans instead of
   one explicit session state machine and one explicit turn state machine.
5. Recovery and rehydration are launcher-oriented. They are not modeled as
   explicit conversation-domain events with generation and sequence guards.

## Design goals

The redesign must:

- make session lifecycle, turn lifecycle, and user attention separate typed
  concepts
- make durable transcript history authoritative
- keep a live overlay for immediacy
- make command idempotency explicit
- make stale generation and stale update rejection explicit
- move provider translation and lifecycle ownership into the daemon
- reduce `ChatDetailView` to presentation and user intents
- keep the renderer path stable through a compatibility projection

## Compatibility rules

This redesign must preserve these contracts for newly created chat data:

- SQLite raw identifiers stay primitive strings at persistence boundaries
- JSON and XPC payloads still cross as encoded `Data`
- CLI output shapes stay stable unless an additive extension is versioned
- File Provider output shapes stay stable
- wiki-link syntax stays stable
- raw ULID string formats stay stable
- SwiftPM command-line builds stay the only supported build path

This redesign may break these things at schema v46:

- existing chats
- existing chat messages
- chat search rows
- chat embeddings
- stored ACP session handles
- existing `[[chat:...]]` references that point to deleted chats

This redesign must preserve:

- pages
- sources
- settings
- links
- non-chat wiki data

## Paseo patterns to copy

This redesign uses Paseo as an architecture reference, not as code to copy.

Key patterns from Paseo:

- [`~/work/paseo/docs/timeline-sync.md`](~/work/paseo/docs/timeline-sync.md)
  keeps two delivery paths: a live stream for immediacy and authoritative
  history for correctness.
- [`~/work/paseo/docs/agent-lifecycle.md`](~/work/paseo/docs/agent-lifecycle.md)
  keeps lifecycle state explicit and separate from view layout.
- [`~/work/paseo/packages/server/src/server/agent/agent-manager.ts`](~/work/paseo/packages/server/src/server/agent/agent-manager.ts)
  owns authoritative session state, event sequencing, attention, and replay.
- [`~/work/paseo/packages/server/src/server/agent/providers/acp-agent.ts`](~/work/paseo/packages/server/src/server/agent/providers/acp-agent.ts)
  keeps ACP provider translation and runtime ownership inside the daemon-side
  runtime boundary.

Patterns we will use:

1. Keep the live stream for immediate updates.
2. Keep durable history as the source of truth.
3. Add a session generation and update sequence.
4. Reject stale or missing updates explicitly.
5. Separate session lifecycle, active-turn lifecycle, and user attention.
6. Let a pure client reducer combine durable history and transient overlay.

## Architecture summary

The redesign has six primary touch points:

1. `WikiFSTypes` gets strong identifiers and tagged context references.
2. `WikiFSEngine` gets the typed conversation domain, reducers, commands,
   snapshots, runtime protocol, and scripted runtime.
3. `WikiFSCore` gets durable turn metadata and typed transcript persistence.
4. `wikid` replaces launcher-shaped orchestration with per-chat controllers.
5. The app replaces flat mirrored flags with a sequenced client projection.
6. `ChatDetailView` becomes a composition root for focused views.

## Phase plan

### Phase 0: Record the architecture and add test infrastructure

1. Create this design record and add it to `PLAN.md`.
2. Add a scripted chat-runtime harness before changing production behavior.
3. Add characterization tests for external contracts that stay after reset.

Phase 0 deliverables:

- `ChatAgentRuntime` protocol in `WikiFSEngine`
- closure-backed runtime seam that characterizes the current launcher/backend
  boundary without yet replacing it
- deferred from this foundation PR: the production `AgentLauncher`/ACP adapter
  that will implement the runtime protocol against the real launcher/backend
  path without changing external behavior
- `ScriptedChatRuntime` in test support
- deterministic pause gates for ordered lifecycle testing
- characterization tests for raw identifier boundaries, CLI/File Provider
  output shape preservation, and wiki-link stability

### Phase 1: Add strong identifiers and the conversation domain

1. Add Foundation-only identifiers in `WikiFSTypes`:
   - `ChatTurnID`
   - `ChatMessageID`
   - `ChatCommandID`
   - `ChatSessionGenerationID`
   - `ChatUpdateSequence`
   - `PermissionRequestID`
   - `PermissionOptionID`
2. Move `ToolCallID` from `WikiFSEngine/ACPModelValueTypes.swift` into
   `WikiFSTypes` and re-export it to existing callers.
3. Reuse `AcpSessionID` from `WikiFSTypes`.
4. Add `ChatContextReference` with `.page(PageID)`, `.source(SourceID)`, and
   `.chat(ChatID)`.
5. Add `ChatTurnSubmission` with typed ids, text, references, and timestamp.
6. Add Foundation-only `ChatTranscriptItem` value types in `WikiFSTypes`.
7. Add orthogonal session, turn, attention, command, update, and snapshot
   state in `WikiFSEngine`.
8. Add `ChatTranscriptReducer` and pure state-machine logic in `WikiFSEngine`.

### Phase 2: Add durable turns and typed transcript persistence

Schema v46 rebuilds the chat subsystem. It deletes old chat data and recreates
typed chat tables. It preserves non-chat wiki data.

Phase 2 deliverables:

- schema v46 destructive rebuild for chat-owned tables only
- durable queued-turn persistence with typed lifecycle metadata
- atomic turn claim and provider-submission boundaries
- typed transcript persistence with compatibility projection to `AgentEvent`
- cursor-based transcript paging and checkpoints
- Tantivy rebuild invalidation marker for chat-owned search reset
- store and migration coverage for the destructive reset boundary

### Phase 3: Move lifecycle ownership into per-chat daemon controllers

Replace `DaemonChatHost` launcher-oriented orchestration with a per-chat
controller that owns generation, queue, permissions, replay buffer, and
runtime lifecycle.

### Phase 4: Replace the chat XPC mirror with sequenced snapshots and a pure client reducer

Version the wire payload, keep `Data` transport, add typed snapshots and
updates, and replace `RemoteChatSession` with a reducer-owned client store.

This phase is out of scope for this branch.

### Phase 5: Decompose the chat UI around the presentation model

Reduce `ChatDetailView` to a composition root over focused child views and a
pure presentation projection.

This phase is out of scope for this branch.

### Phase 6: Remove compatibility layers and update documentation

Delete old shims after all call sites migrate. Keep only raw boundary adapters
that remain required.

This phase is out of scope for this branch.

### Phase 7: Execute with coordinated Paseo agents

After plan approval, use coordinated agents with non-overlapping ownership for
domain, persistence, daemon, client-sync, UI, verification, and integration.

This branch does not execute the full multi-agent implementation plan. It only
uses the minimum sidecar delegation needed for this foundation PR.

## Domain model

### Identifier rules

- Every chat-domain identifier gets its own wrapper type.
- Raw strings cross only at SQLite, JSON, ACP, CLI, or File Provider
  boundaries.
- Compile-time APIs must not accept raw `String` where an id type exists.
- `AcpSessionID` remains the provider-session namespace.

### Context references

`ChatContextReference` is a tagged enum:

- `.page(PageID)`
- `.source(SourceID)`
- `.chat(ChatID)`

This prevents page, source, and chat ids from colliding in one untyped string
field.

### Transcript vocabulary

`ChatTranscriptItem` becomes the shared Foundation-only transcript vocabulary.
It must cover:

- user message
- assistant message
- reasoning
- tool call
- system notice
- turn failure

Message items carry:

- `ChatMessageID`
- `ChatTurnID`

Tool-call items carry:

- `ToolCallID`
- typed status: `pending`, `running`, `completed`, `failed`, `cancelled`
- typed detail
- optional permission link

`WikiFSCore` keeps the projection to `AgentEvent` for the current renderer.

### Session state

Session lifecycle:

- `unavailable`
- `starting`
- `ready`
- `recovering`
- `closing`
- `closed`
- `failed`

Turn state:

- active nonterminal cases:
  - `queued`
  - `submitting`
  - `responding`
  - `awaitingPermission`
  - `cancelling`
- typed terminal outcomes

Recovery policy for this foundation branch:

- `sessionClosed` clears only active execution state and attention; it preserves
  queued user turns.
- `sessionReady` may recover from `starting`, `recovering`, `unavailable`,
  `closing`, `closed`, or `failed`.
- when `sessionReady` arrives for a recovered snapshot with no active turn but
  preserved queued turns, the first queued turn is promoted back to active
  `.queued` state and the remaining queue keeps arrival order.
- `recovering` is allowed only from `starting`, `ready`, `failed`, or
  `closing`.

Attention state:

- `none`
- `permissionRequired`
- `turnFailed`
- `interruptedTurn`

Capabilities:

- resume
- close
- modes
- models
- configuration options
- reasoning
- tools
- permissions

Snapshot state includes:

- chat identity
- generation
- lifecycle
- active turn
- queued turns
- attention
- capabilities
- provider state
- usage
- diagnostics
- transient transcript overlay
- committed-transcript cursor
  - deferred in this foundation branch: durable transcript persistence and
    client sync do not exist yet, so the runtime snapshot intentionally keeps
    only the transient overlay plus the per-generation update watermark
- `lastIncludedSequence`

Derived UI capabilities must come from composite state. They must not be stored
as independent booleans.

### Commands and updates

New typed intents:

- create chat
- submit turn
- cancel turn
- edit queued turn
- remove queued turn
- retry interrupted turn
- resolve permission
- set configuration
- request snapshot
- close session

Rules:

- `ChatCommandID` is idempotent.
- Repeating a command must not duplicate a turn or message.
- `editQueuedTurn` keeps the existing `ChatTurnID`.
- `retryInterruptedTurn` creates a new `ChatTurnID`.
- `ChatSessionUpdate` carries `chatID`, `generation`, `sequence`, and a typed
  payload.
- Terminal outcomes must be explicit. No caller may infer completion from a
  process flag.

## Acceptance criteria

### AC.1

Strong types prevent chat, turn, message, command, permission, page, source,
queue-item, and provider-session identifiers from crossing the wrong API at
compile time. Existing raw strings still round-trip at external boundaries.

### AC.2

The daemon accepts one typed submit intent for new, warm, dead, or persisted
chats. It creates or resumes the required provider session without app-side
start-versus-continue branching.

### AC.3

The daemon state machine permits only documented session and turn transitions.
Stale generation, stale turn, duplicate terminal, duplicate command, and
illegal permission events do not mutate current state.

### AC.4

A submitted follow-up during an active turn becomes a durable queued turn. It
survives view recreation and app restart, preserves order, and uses at-most-once
provider submission.

### AC.5

Live transcript updates and persisted transcript rows converge by typed item
identity.

### AC.6

Completion, failure, cancellation, watchdog recovery, and transport exit each
produce exactly one terminal turn outcome.

### AC.7

Permission requests preserve all typed options and tool-call identity across
ACP, daemon state, XPC, client projection, and UI.

### AC.8

ACP resume or load uses the stored provider session when supported. Permanent
failure uses an explicit bounded preamble fallback, clears only the stale
session handle, and keeps the same `ChatID`, turn order, and transcript.

### AC.9

The v46 migration and fresh schema create equivalent turn and typed transcript
storage. Migration deletes old chat data while preserving non-chat data.

### AC.10

The app detects duplicate and missing sequenced updates, requests an
authoritative snapshot after a gap, and catches up without replacing known
history with an unrelated tail.

### AC.11

The chat interface shows correct typed lifecycle states. Composer, queue,
cancel, and permission actions match derived capabilities.

### AC.12

`ChatDetailView` no longer owns lifecycle reduction, live-versus-persisted
selection, queue delivery, permission parsing, or start-versus-continue
routing.

### AC.13

All Swift code compiles and tests through SwiftPM from the command line.

### AC.14

Architecture and progress documents describe the final state, compatibility
contracts, and verified test evidence.

### AC.15

`ScriptedChatRuntime` provides deterministic, sleep-free control of ordered
lifecycle events.

## Test strategy

This redesign needs new deterministic test layers.

### Pure domain tests

- reducer transitions
- stale generation rejection
- duplicate terminal rejection
- duplicate command rejection
- permission resolution behavior
- derived capability calculations

### Store tests

- schema migration
- fresh-schema parity
- durable queue ordering
- checkpoint persistence
- cursor paging
- change-event emission

### Daemon/controller integration tests

- ordered runtime events
- start, stream, permission, queue, complete, cancel, failure, exit, and resume
- at-most-once claim behavior
- replay buffer and snapshot watermark behavior

### Client reducer and XPC tests

- DTO round-trip
- wire-version rejection
- duplicate, stale, gap, reconnect, optimistic turn, and overlay reconciliation

### Hosted macOS tests

- attention, queue, composer, lifecycle state, accessibility labels, and
  transcript rendering compatibility

### Live smoke test

- opt-in ACP smoke test only

## Named tests

The umbrella plan names these test suites:

- `ChatIdentifierBoundaryTypecheckTests`
- `ChatDomainAPISignatureManifestTests`
- `ChatIdentifierCodableCompatibilityTests`
- `ChatSessionMachineTransitionTests`
- `ChatSessionMachineStaleEventTests`
- `ChatCommandIdempotencyTests`
- `ChatTranscriptReducerTests`
- `ScriptedChatRuntimeTests`

Later phases add more suites for persistence, daemon restart, client sync, and
UI decomposition.

On the corrective branch (`chat-domain-audit-fixes`), the implemented coverage
maps to these concrete suites:

- `ChatIdentifierBoundaryTypecheckTests` is currently enforced by
  `IdentifierBoundaryTypecheckTests`, including the launcher and chat-domain
  positive fixtures and the negative namespace fixtures run through
  `swiftc -typecheck`.
- `ChatSessionMachineTransitionTests` and
  `ChatSessionMachineStaleEventTests` are currently covered by
  `ChatDomainStateTests` and `ChatDomainAuditRegressionTests`.
- `ChatCommandIdempotencyTests` is intentionally deferred to the Phase 3
  controller-level command-dedup work. Phase 0/1 coverage here is the reducer
  and event negative matrix in `ChatDomainStateTests` and
  `ChatDomainAuditRegressionTests`, not an assertion that `ChatCommandID`
  deduplicates submitted commands yet.
- `ScriptedChatRuntimeTests` keeps its own suite, with additional runtime seam
  coverage in `ChatAgentRuntimeCoverageTests`.

The current verification evidence for this branch is macOS-hosted. The
typecheck fixtures still keep Linux target-triple support in the test harness,
but that is a compatibility guard in code, not a claim that Linux CI ran here.

## Review strategy

Before and during implementation:

1. Use `swift-testing-pro` before new tests.
2. Use `swift-concurrency-pro` before runtime streams, pause gates, and
   cross-actor work.
3. Use `swiftui-pro`, `macos-design`, and `typography-designer` before UI work.
4. Run a review focused on silent error handling, stale-event isolation,
   duplicate terminal behavior, persistence ordering, actor boundaries, missing
   tests, and obsolete compatibility code.

## Risks

1. Typed transcript work can expand into a renderer rewrite. This plan keeps
   the current renderer through an `AgentEvent` projection.
2. Schema v46 is destructive. Tests must prove that non-chat data survives.
3. App and daemon ship together, but stale processes can still exist during
   development. Wire versioning must fail clearly.
4. Cancellation, completion, watchdog, and transport-exit races can produce
   duplicate terminal paths unless the controller has one terminal winner.
5. Actor reentrancy can break controller invariants if code assumes state after
   an `await`.
6. Large histories cannot fit in every snapshot. Cursor pages are required.
7. Compatibility cleanup can land too early if old shims are removed before all
   callers migrate.

## Decisions already made

- The daemon owns chat lifecycle and durable queued turns.
- The app sends typed intents and renders a reducer projection.
- Durable history is authoritative. Live updates are an overlay.
- Session lifecycle, turn lifecycle, and attention are separate typed states.
- Schema v46 may reset chat-owned data.
- The current transcript renderer stays in scope through a projection.

## Branch scope for this PR

This PR implements the foundation, persistence, and controller work:

- this design record and the `PLAN.md` index entry
- strong Foundation-only chat identifiers
- tagged context references
- shared transcript item vocabulary in `WikiFSTypes`
- `ToolCallID` move into `WikiFSTypes`
- `ChatAgentRuntime` protocol and production seam
- deferred but still planned from the original Phase 0 framing: the production
  `AgentLauncher`/ACP adapter that will plug the runtime protocol into the real
  launcher/backend path
- `ScriptedChatRuntime` test support
- orthogonal session, turn, attention, capability, command, update, snapshot,
  and replay-buffer value types
- pure reducer and state-machine logic
- schema v46 destructive chat-subsystem rebuild that preserves non-chat data
- durable queued-turn persistence with typed claim / submission / terminal
  boundaries
- typed transcript persistence, compatibility projection, cursor paging, and
  checkpoints
- per-chat daemon controllers with generation-guarded runtime event handling,
  durable queue recovery, restart interruption marking, terminal-outcome
  winner enforcement, typed snapshot production, and bounded replay
- daemon/client compatibility migration to one typed submit path through the
  daemon contract, client wrapper, coordinator, and `ChatDetailView`
- Tantivy rebuild marker invalidation for destructive chat search resets
- direct controller, host, and coordinator tests for Phase 3 lifecycle,
  restart, stale-event, replay, and compatibility cases
- tests for AC.1, AC.2, AC.3, AC.4, AC.5, AC.6, AC.7, AC.8, AC.9, AC.13,
  AC.14, and AC.15

Out of scope for this PR:

- XPC wire redesign
- client synchronization migration
- UI decomposition

## Verification commands

Run from the repository root:

```sh
make prompts
make build
make test
WIKIFS_APP_TESTS=1 swift test
WIKIFS_APP_TESTS=1 TEST_TIMEOUT=60 make test-watchdog
```

If the local mutation tool is available, also run:

```sh
make mutate-scope SOURCES_PATH=Sources/WikiFSEngine
```
