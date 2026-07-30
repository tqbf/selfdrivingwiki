# Chat presentation and diagnostics

## Purpose

Complete the chat presentation layer. Provider output, durable transcript items,
client synchronization, and the macOS transcript must preserve turn and
content-block boundaries. The app must stop converting typed transcript items
back to `[AgentEvent]` through `ChatTranscriptProjection`.

This record builds on the typed conversation domain in `WikiFSTypes` and
`WikiFSEngine`. `ChatTranscriptItem`, `ChatMessageID`, `ChatTurnID`,
`ToolCallID`, `ChatClientSyncState`, and `ChatTranscriptReducer` remain the
durable and synchronization vocabulary.

## Scope and compatibility

Keep the current SQLite schema shape, raw identifier values, JSON/XPC `Data`
transport, File Provider and CLI formats, wiki-link behavior, markdown renderer,
and one-WebView text selection. Add a wire field only when it is necessary and
version it with backward decoding.

Do not persist UI lifecycle state in `ChatTranscriptItem`. The client derives
streaming state from explicit, non-persisted active-block metadata. Do not make
reasoning visible beyond its existing collapsed treatment. Keep queue activity
on its own `AgentEvent` adapter unless it deliberately adopts a typed row
contract.

## Pipeline

```text
provider event
  -> daemon content-block translator
  -> typed transcript delta and active block
  -> durable store plus live overlay
  -> sequenced client synchronization
  -> typed display sections and rows
  -> keyed render plan
  -> serialized WebKit command acknowledgement
```

Live deltas and canonical history are distinct paths. Canonical history
replaces overlapping live content. A rendered index is never an identity.

## Type ownership

| Target | Owns |
| --- | --- |
| `WikiFSTypes` | durable notice and failure IDs, transcript values, shared diagnostic DTOs |
| `WikiFSEngine` | reduction anomalies, live-block sync metadata, reconciliation |
| `wikid` | provider translation, block state, durable ID creation, daemon diagnostics |
| `WikiFS` | display projection, row lifecycle, renderer planner and executor, app trace/export |

App display types must not enter `WikiFSTypes`, `WikiFSCore`, or daemon targets.
The daemon may use shared diagnostic DTOs without importing the app target.

## Phase 1: transcript content-block identity

Add characterization tests around
`LauncherChatAgentRuntime.transcriptDeltasForTesting` and
`ChatTranscriptReducer.reducing`. Test assistant-tool-assistant, delta-tool-
delta, reasoning-assistant-reasoning, two provider blocks in one turn, and a
delta followed by a full replacement.

Replace the per-role `assistantMessage` and `reasoningMessage` optionals with
one finite state machine. It has either no open block or one typed open block
with a message ID, role, creation time, and accumulated text. A compatible
delta or replacement updates only that block.

Tool use, tool result, user content, system notices, failures, terminal events,
and role changes close the block. A later assistant or reasoning block gets a
new `ChatMessageID`, even in the same turn. A compatible final text event
finalizes the current block. Provider block identity is preferred when it
exists. Generated IDs stay stable for one translated block. Duplicate terminal
events are idempotent and cannot reopen a final block.

Tool calls retain independent `ToolCallID` identity and update in place. Keep a
documented FIFO compatibility fallback only when the provider does not expose a
call ID. Do not use it for assistant block identity.

The transcript reducer validates message ID, turn ID, and role before mutation.
Its diagnostic-capable API returns a typed anomaly for mismatches. A convenience
normal-reduction API can remain as an adapter.

## Phase 2: durable non-message IDs and active-block metadata

Add `ChatTranscriptNoticeID` and `ChatTranscriptFailureID`, or one equivalent
namespaced durable item ID, to notices and failures. The daemon creates each ID
once at ingestion. Overlay, persistence, snapshots, replay, and presentation
carry it unchanged. Equal notice or failure values must still have different
identities.

At a named `GRDBWikiStore` schema migration after v46, rewrite legacy
`chat_transcript_items.item_json` payloads that lack these IDs. Use one store
transaction and a versioned namespace over `(chatID, persisted cursor, item
kind)`. The migration is idempotent and does not change table layout. It stamps
the migration only after every payload rewrite succeeds. The fresh-schema path
and schema-version comments advance with this migration. A read-only store does
not repair legacy rows.

Normal `ChatTranscriptItem` decoding requires the new durable IDs. Its leaf
decoder returns a typed missing-identity error for a legacy raw payload. A
separate legacy raw-item decoder exists only at a context-bearing store/page or
wire-envelope adapter. Raw `JSONDecoder().decode(ChatTranscriptItem.self, ...)`
is therefore not a legacy compatibility contract.

The persisted page/store adapter can synthesize fixture compatibility IDs from
`(chatID, cursor, kind)`. A legacy projection envelope uses a typed
`LegacyTranscriptOccurrence` that includes chat ID, generation, update or
snapshot sequence, source ordinal, and item kind. This ordinal is provenance,
not a display index. Canonical migrated history replaces a matching legacy
overlay by cursor or update provenance. An old overlay without enough provenance
emits an anomaly and canonical history wins.

Add non-persisted `ChatActiveContentBlock` metadata to `ChatSyncProjection`.
It contains message ID, turn ID, role, and a phase that cannot represent a
finalized block as open. The daemon controller sets it when a block opens and
clears or replaces it before every semantic boundary. The client validates the
referenced item, role, turn, generation, and sequence. It clears stale metadata
on reconnect and canonical snapshot unless that snapshot carries a valid block.
Absent metadata decodes as `nil` for old wire payloads.

Treat active-block propagation as one atomic wire change. Update
`ChatSyncProjection`, its `from` and Codable paths, `ChatSyncWire.WireUpdate`
field copying and transcript-delta reconstruction, snapshot and update
envelopes, `DaemonChatController.syncProjection`, and
`DaemonChatHost.persistedOnlySessionState`. Test both ordinary projection
Codable and `ChatSyncWire.encodeData` and `decodeData` delta modes. Translator
output carries transcript deltas and the active-block transition together. The
controller applies the close or replacement before it publishes the matching
boundary update.

Change the persistence and sync identity keys for notices and failures in the
same phase. `GRDBWikiStore.appendChatTranscriptItems`, transcript-cursor
deduplication, and `ChatClientSyncReducer.TranscriptIdentity` use their durable
IDs, not complete value equality. Test duplicate-equal notices and failures
through the real persistence append, committed/overlay merge, and display
projection. Changing the client reducer alone is insufficient.

## Phase 3: typed presentation projection

Create app-only `ChatDisplayTranscript`, `ChatDisplaySection`,
`ChatDisplayTurn`, `ChatDisplayUnattributedSection`, `ChatDisplayRowID`, and
`ChatDisplayRow`. Row IDs are a namespaced enum over message, tool-call,
notice, and failure IDs. A content-state enum gives only assistant and
reasoning rows `streaming` or `final` lifecycle. Tool status uses
`ChatToolCallStatus`. Failures carry `ChatTurnFailureCategory`.

`ChatDisplayProjection` is pure. It consumes reconciled
`ChatClientSyncState.displayTranscriptItems` and validated active-block
metadata. It preserves every input identity and global order exactly once. It
groups contiguous turn IDs without merging different messages. If a turn ID
reappears after another turn, it starts an anomalous new section instead of
moving intervening rows.

Notices before the first turn and between turns remain ordered unattributed
sections. Their section IDs derive deterministically from contained durable row
IDs. A paged turn can omit its prompt. The projection validates input/output ID
multisets and order and emits typed loss, duplication, or reorder anomalies.

Make typed transcript items and validated active-block metadata the primary
client contract. Delete `displayEvents`, `displayEventTimestamps`,
`RemoteChatSession.events`, timestamp arrays, and launcher-era presentation
booleans after all app callers migrate. `ChatDetailPresentation.Transcript`
holds sections and rows. Outline entries use `ChatTurnID` and row identity.
Permission actions use `PermissionOptionID` and a typed resolution intent.

## Phase 4: native transcript UI

Keep `ChatDetailView` as the composition root. `ChatTranscriptPaneView` accepts
typed presentation values and typed intents. It does not read daemon or store
authority indirectly.

A user prompt starts one visual turn. Assistant blocks retain separate visual
rows. Reasoning stays subdued and collapsed. Tool rows appear between blocks and
update in place. Notices and failures use semantic treatment. A turn footer can
show elapsed time or status. Per-message copy stays with its message.

Use system fonts, semantic colors, hover-revealed secondary actions, keyboard
copy, light and dark appearance, reduced motion, named metrics, and one scroll
surface. The WebView CSS keeps a readable prose measure and line spacing while
preserving `pageZoom`.

Rows expose semantic DOM roles, state labels, accessible disclosure and copy
names, and non-color-only running and error cues. Row replacements cannot steal
VoiceOver focus. Follow state is a typed finite state machine. Streaming follows
only near the bottom. Earlier readers keep their position, selection, anchor,
and focused element.

## Phase 5: keyed, acknowledged WebKit rendering

Extract a pure `ChatTranscriptRenderPlanner`. It accepts the previous and
desired rows plus transcript identity. It returns `reload`, `insert` or
`append`, `replace`, `remove`, or `no-op` commands. A transcript/style/reset
change or unrecoverable reorder uses reload. A same-ID change uses replace. A
different ID at equal count never means replace-last.

Each row receives a safely encoded stable DOM `data-row-id`. JavaScript targets
that identity only. Indices exist only while the planner computes the desired
order. Finality comes from the input row, never from array position. Embeds run
only for explicitly final assistant or reasoning rows.

`ChatTranscriptRenderExecutor` is main-actor isolated and has `idle`,
`applying(command, revision)`, and `awaitingReload` states. One JavaScript
mutation is in flight. Completion acknowledges a revision before the next
command. The executor may coalesce pending replacements for one row to their
latest value. It cannot coalesce or reorder different rows across an append
boundary.

Extend hosted WebKit support with a timeout-bounded result helper. It separates
successful values, `undefined`, JavaScript exceptions, and timeout. Mutation
scripts return typed acknowledgement objects with command kind, revision, row
ID, and outcome. Missing rows or errors emit a renderer anomaly, do not advance
acknowledged state, and schedule one controlled reload from the latest snapshot.

## Phase 6: correlated diagnostics

Add Foundation-only `ChatDiagnosticTypes.swift` in `WikiFSTypes`. It defines a
versioned event and snapshot envelope, source process, process instance UUID,
per-process sequence, timestamp, redaction metadata, typed stage, payload, and
outcome. Stages cover provider receipt and translation, reduction and
persistence, sync acceptance and reconciliation, display projection, render
planning, DOM acknowledgement or failure, and recovery reload.

Events carry correlation values where available: chat, generation, update
sequence, turn, durable item, display row, tool, cursor, renderer revision,
event kind, content length, and a keyed fingerprint. They never carry message
text, an unsalted digest, or a reusable plaintext-derived token. Each local
trace creates a random key and process-instance identity. It stores only a
versioned keyed digest and length. Successful export or trace reset rotates the
key, instance identity, and ring.

Use a dependency-light diagnostic sink. Unified logging is the normal sink.
High-frequency deltas are coalesced by message or revision and debug gated.
Anomalies remain notice or error logs. Each process owns its own bounded,
serialized per-chat ring. Named policy constants define record and byte limits,
oldest-first eviction, JSONL record and byte caps, rotation, and surfaced write
errors. The app ring and export merge live in `WikiFS`. The daemon JSONL stays
with existing daemon/run logging.

Add an XPC snapshot request through the daemon host harness. The app merges its
own sync, projection, renderer, and trace snapshot with the daemon response by
source and per-process sequence. Timestamps provide only approximate order.
Timeout, decode, and version failures become explicit snapshot and log entries.
The export reports runtime/sync summaries, identities, active block, display
rows, revisions, traces, drop counts, and merge metadata. Copy Diagnostics is
redacted by default. Full-content artifacts remain a separate explicit debug
folder workflow.

Add a versioned `Data`-only diagnostic method to `WikiDaemonProtocol`. Thread it
through `wikid/main.swift`, `WikiDaemon`, daemon host and controller, the app
coordinator/client, Linux or non-AppKit stubs, and exported-object interface
tests. Validate its version at the protocol boundary and bound every app-side
request with a timeout. A shared DTO alone is not an XPC endpoint.

Replace numbered `DebugLog.chatLive` observation seams in the chat detail,
sidebar, session, and Agent Tools surfaces with typed events. Document the
stable `log show` predicate and expose these controls only under existing debug
controls.

## Phase 7: remove compatibility debt and document

Delete chat UI uses of `ChatTranscriptProjection.project`, `[AgentEvent]`
presentation, parallel timestamp arrays, event-count rendering, last-row
inference, and launcher-shaped session events. Keep `AgentEvent` only at a real
provider or activity-feed boundary. Add API and import-manifest tests to prevent
the compatibility surface from returning.

Retain the Core-only projection that writes legacy `projected_event_json` and
`projected_text` compatibility columns until a separately versioned persistence
contract replaces those columns. Rename or document that adapter so no app UI
code can depend on it. This migration removes the app renderer compatibility
surface, not the durable SQLite compatibility write path.

Update `plans/chat-architecture-redesign.md` to mark its deferred renderer
migration complete and link here. Add this plan to `PLAN.md`. Add an execution
record under `progress/` only after implementation. Update troubleshooting and
user documentation for visible blocks, tool rows, copy, and diagnostic export.
Do not expose internal terms such as overlay, reducer, or DOM revision to users.

## Required characterization and verification

Use Swift Testing for all new unit and integration tests. Inject clocks and ID
factories. Add a scripted typed transcript scenario that can run through the
translator, reducer, sync, display projection, and render planner without
delays. Include mutation-sensitive identity and lifecycle assertions.

Required coverage includes:

1. Assistant, tool, assistant yields two distinct message IDs and display rows.
2. Deltas and final replacements update one block. Boundaries close it.
3. Committed history and live overlay converge without loss, duplication, or
   concatenation for every transcript kind.
4. Legacy store and wire identity migration is repeatable, idempotent, and
   canonical history wins over an ambiguous legacy overlay.
5. Display output preserves input identity and order, including unattributed
   sections, paged prompts, and non-contiguous turns.
6. Typed app APIs reject `AgentEvent` rows, raw ID strings, and untyped
   permission resolution.
7. Planner and injected executor preserve command order and recover from a
   failed patch with exactly one latest-snapshot reload.
8. Hosted WebKit tests assert DOM row IDs, count, order, text, streaming or
   final attributes, selection, scroll anchor, focus, semantic roles, reduced
   motion, copy, wiki links, quote highlight, zoom, and appearance.
9. Diagnostic tests prove correlation, redaction, per-export fingerprint
   rotation, ring eviction, coalescing, JSONL rotation, verbose gating, and
   daemon/app snapshot merge.
10. Target-import, external-contract, documentation-manifest, XPC, and hosted
    AppKit suites protect all ownership and compatibility boundaries.

Run `swift test --filter LauncherChatAgentRuntimeTests`, focused reducer,
presentation, planner, diagnostics, XPC, and identity suites, `make build`,
`make test`, and `WIKIFS_APP_TESTS=1 swift test` under
`HostedAppKitTestGate`. Run the SwiftUI runtime-issue log capture while the
hosted suite executes. Run `make mutate-scope SOURCES_PATH=Sources/WikiFSEngine`
when the local tool is available and report it separately.

## Review and implementation rules

Before implementation, review this plan for dependency order, target ownership,
legacy migration, WebKit actor safety, and SwiftPM constraints. During work,
consult the Swift concurrency and testing guidance. Consult the SwiftUI, macOS,
and typography guidance before and after transcript UI changes. Do not use
`@unchecked Sendable`, bare `try?`, `print` diagnostics, or synchronous SwiftUI
state writes from `NSViewRepresentable` update paths.

Before handoff, run an implementation review for block identity, lifecycle
states, reconciliation, WebKit acknowledgement/recovery, privacy and logging,
and hosted coverage. Fix or explicitly rebut every critical or high finding.
