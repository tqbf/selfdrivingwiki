# Chat UI + persistent chat (issue #119)

**Status: shipped.** Ask/Edit conversations persist to the wiki's SQLite
store, render through a unified `ConversationView` with live streaming, can
be continued (seeded-fallback), renamed, and browsed from the sidebar. The
conversation layer is decoupled from the Claude-CLI wire protocol behind an
`AgentBackend` port so a future backend (ACP, Polytoken) is a drop-in.

This document supersedes three earlier plan docs (`persisted-chat-history.md`,
`conversation-ui.md`, `agent-backend-port.md`), which have been deleted.

## What shipped

| Slice | What it does |
| --- | --- |
| **Phase 0 — AgentBackend port** | `AgentBackend` protocol (`start`/`send`/`resume`/`cancel`) + `ClaudeCLIBackend` (actor) wrapping the spawn/parse/encode behind a per-turn `AsyncStream<AgentEvent>`. The launcher never touches a `Process` or wire format. Behavior-preserving. |
| **A.1 — WikiRenderContext** | Pure `Sendable` value type capturing the reader's full render precompute (existence/display/loose sets, embedMap, sourceDerivedChain `@vN`, siblingMaps) + the four closures. Memoized on `WikiStoreModel`, invalidated by `WikiEventBus`. Reader refactored onto it (behavior-preserving). |
| **A.2 — Transcript render context** | `WikiRenderContext` threaded into `AgentTranscriptWebView` (current-per-render provider). `BlobSchemeHandler` registered on the transcript `WKWebView`. Two-tier streaming render: links-only while streaming, full embeds on finalize. |
| **D2 — Unified ConversationView** | One surface for live (streaming) + persisted (browsed) chat via the source-of-truth rule (`activeChatID == chatID ? launcher.events : store.chatMessages`). Flip gated on final flush commit (no truncation). Draft-state morph (`.ask`/`.edit` → `.chat(id)` on first send). `startNewConversation` retarget-back. `ChatHistoryDetailView` deleted + absorbed. |
| **D3 — Continue a persisted conversation** | Seeded-fallback: takeover rules (idle take / between-turns stopAgent+flush-then-take / mid-gen refuse), byte-capped `continuationPreamble`, same-row append (seq continues, title preserved). Display text separated from send text (user sees their message, not the preamble). Per-session `currentRunToken` guard against stale `onExit`. |
| **D4 — Sidebar affordances** | `+` New Conversation menu, Rename Conversation context menu, live indicator (circle.fill + "responding…"), Ask/Edit subtitles. |

## Architecture

```
 ┌─────────────┐     per-turn AsyncStream      ┌──────────────────┐
 │ AgentBackend │ ◀────────────────────────── │  AgentLauncher    │
 │  (protocol)  │   start / send / cancel       │  @MainActor       │
 └──────┬───────┘                               │  @Observable      │
        │                                       │  events[], gates, │
        ▼                                       │  locks, flush     │
 ┌──────────────────┐                           └────────┬──────────┘
 │ ClaudeCLIBackend  │                                    │
 │  (actor)          │                           ┌────────▼──────────┐
 │  Process + pipes  │                           │ ConversationView   │
 │  AgentEventParser │                           │  source-of-truth:  │
 │  streamJSONLine   │                           │  live vs persisted │
 └──────────────────┘                           └────────┬──────────┘
                                                          │
                                                ┌─────────▼──────────┐
                                                │ SQLiteWikiStore     │
                                                │  chats + chat_      │
                                                │  messages (v25)     │
                                                └────────────────────┘
```

The launcher holds an `AgentBackend` + `SessionHandle` and consumes a
per-turn `AsyncStream<AgentEvent>`. `mergeOrAppend` (delta coalescing) stays
in the launcher — it's transcript UI state, not wire format. The backend
yields raw `.assistantTextDelta`/`.assistantText`; the launcher coalesces.

### Turn-boundary contract

Every backend impl MUST yield `.messageStop` at each turn end. The launcher
keys its generation-gate release, edit-lock release, and transcript flush off
`AgentEvent.endsGeneration` (true for `.result` and `.messageStop`). A backend
that fails to synthesize `.messageStop` strands the edit lock and the spinner.

### Concurrency shape (validated against `swift-concurrency-pro`)

- `ClaudeCLIBackend` is an `actor` (holds `Process` — not `Sendable`). No
  `@unchecked Sendable`.
- Per-turn `AsyncStream` via `makeStream(of:)`; the `readabilityHandler`
  captures the `Sendable` `ContinuationBox`, decodes off-main, yields.
- Continuation finished EXACTLY ONCE: at `endsGeneration` (turn boundary) or
  `terminationHandler` (process exit). `onTermination` distinguishes
  `.cancelled` (tear down process) from `.finished` (natural turn end, process
  stays alive for next turn).
- `.unbounded` buffering — tokens must never be dropped.
- `onExit` fires exactly once via a one-shot `OnExitGate`. The launcher's
  `currentRunToken` guard ensures a stale `onExit` (a prior session
  terminating after a new one started — e.g. D3's takeover) does not tear down
  the new session.

## Data model

### Schema v25 (chats + chat_messages)

Two tables in the per-wiki SQLite store:

```sql
CREATE TABLE chats (
    id         TEXT PRIMARY KEY,      -- ULID, stable resource identity
    kind       TEXT NOT NULL,         -- 'ask' | 'edit'
    title      TEXT NOT NULL,         -- auto-derived from first user message
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX chats_updated ON chats(updated_at);

CREATE TABLE chat_messages (
    id         TEXT PRIMARY KEY,      -- ULID
    chat_id    TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,      -- dense per-chat ordering, 0-based
    role       TEXT NOT NULL,         -- 'user' | 'assistant' | 'tool' | 'system'
    event_json TEXT NOT NULL,         -- Codable AgentEvent, verbatim
    text       TEXT NOT NULL DEFAULT '',  -- plainText projection (future FTS)
    created_at REAL NOT NULL
);
CREATE UNIQUE INDEX chat_messages_seq ON chat_messages(chat_id, seq);
```

- One row per **persistable** `AgentEvent` (`userText`, `assistantText`,
  `toolUse`, `toolResult`, `subagent`, `result`, `systemInit`). Stream
  bookkeeping events (`assistantTextDelta`, `messageStop`, `raw`) are never
  persisted.
- `event_json` keeps the full typed event so history renders through the
  exact same `AgentTranscriptWebView` pipeline as the live view. `text` is
  the `plainText` projection for future FTS / quote anchors.
- Fresh-path and ladder share `createChatTables()` (`IF NOT EXISTS`),
  enforced by `FreshSchemaParityTests.freshFastPathMatchesStepwiseLadder`.

### Schema version note (v25, not v23)

The chats tables were originally created at v23. **Main branched ahead to
v24** (graph-model Phase 2 close-out: drops the dead
`source_markdown_versions.content` column). A DB opened by main (v24) would
skip the v23 guard (`if version < 23` → false) and never create the chats
tables — `store.chats` was empty, the sidebar's Recent Conversations section
invisible.

**Fix:** chats creation moved to **v25** (above main's v24). `if version < 25`
is true on a v24 DB, so the tables get created. `CREATE TABLE IF NOT EXISTS`
makes it a no-op on DBs that already have them.

v24 (content-column drop) is **not yet merged** into this branch — the dead
`content` column is harmless (writes set it to `''`). It will be merged from
main separately.

### Write path

- `AgentOperationRunner.startQueryConversation` creates the chat row at
  session start (title = first user message, elided) and installs a transcript
  sink on the launcher.
- `AgentLauncher` flushes not-yet-persisted events to the sink at every
  **turn boundary** (`.messageStop` / `.result`) and once more in `finish()`.
  A `persistedEventCount` cursor makes flushes incremental and idempotent.
- The sink captures `WikiStoreModel` **weakly**: a wiki switch mid-session
  degrades to a no-op instead of writing into the wrong wiki.

### Read path

- `WikiSelection.chat(PageID)` — a persisted conversation is a first-class
  selection (tabs, history, drag/drop).
- `ConversationView` renders it via the source-of-truth rule (below).
- The Agent sidebar (`AgentToolsView`) lists recent conversations
  (most-recently-updated first) under the mode rows.

## Render context (pillar 1)

`WikiRenderContext` is a pure `Sendable` value type capturing everything a
markdown render needs from the store. Built once, handed to a detached render
task, never touches SQLite per-delta.

- **Memoized** on `WikiStoreModel` (`store.renderContext()`), invalidated by
  subscribing to `WikiEventBus` (any page/source mutation bumps a generation
  counter; next call rebuilds).
- **Threaded into `AgentTranscriptWebView`** as a provider closure
  (`(() -> WikiRenderContext?)?`) — current-per-render, not load-time.
- **Two-tier streaming:** while a row is streaming, render links only (skip
  `embedInfo` so a half-typed `![[source:…` doesn't instantiate a broken
  iframe). On finalize, re-render once with full embeds. `isFinal: Bool` on
  `rowHTML`.
- **BlobSchemeHandler** registered on the transcript `WKWebView` so
  `wiki-blob://source/<id>` images/media resolve.
- User rows are linkify-exempt (a user typing `[[Foo]]` is not a link).
- nil context (used by `AgentActivityView` internals feed) keeps the
  constant-`true` resolution behavior.

Persisted transcripts get all of this for free because history renders through
the same web view. Old chats *upgrade* — a chat recorded before this phase
gains display-name healing, embeds, and pins the next time it renders.

## Conversation surface (pillar 2)

`ConversationView(mode:chatID:)` is the single surface for live + persisted:

- **Source-of-truth rule:** if `launcher.activeChatID == chatID`, render
  `launcher.events` (streaming, in-memory). Otherwise render
  `store.chatMessages(chatID:).map(\.event)`.
- **Flip timing (load-bearing):** `activeChatID` is cleared in `finish()`
  AFTER `flushTranscript()` commits the final tail. By the time it clears,
  `chatMessages(chatID:)` and in-memory `events[]` agree — the live→persisted
  flip cannot truncate.
- **Draft state:** `.ask`/`.edit` selections (chatID == nil) show the
  empty-composer state. On first send, the runner creates the chat row and
  retargets the tab IN PLACE to `.chat(id)` via `retargetTab` (UUID preserved
  → tab order + history survive).
- **startNewConversation:** clears `activeChatID`, retargets the tab back to
  the draft state. The old chat stays in history.
- `ChatHistoryDetailView` is deleted (absorbed into `ConversationView`).
- `QueryConversationView` kept as a type hosting static predicates
  (`showsNewConversationButton`, `showsEditingBanner`) — still tested, still
  referenced. No longer instantiated for routing.

### Composer gating

- **Live chat:** enabled when a turn isn't in flight.
- **Persisted chat (D3):** enabled when the kind's launcher is idle
  (`!isGenerating && !isAwaitingGenerationSlot`). Disabled with a slot-style
  hint when a different conversation is responding.
- **Draft state:** always enabled (when a wiki is open and nothing is
  generating).

## Continue a persisted conversation (pillar 3)

Seeded-fallback only — no `--resume` (the CLI backend stubs `resume` nil).
Session resume is a backend capability contingent on choosing a backend that
supports it (Polytoken/ACP); deferred.

### Takeover rules

One live session per kind remains the invariant:

- **Idle** → take over directly.
- **Between-turns** (a different conversation's session is open but idle) →
  `stopAgent()` first. That triggers `finish(-1)`, which runs the FINAL
  `flushTranscript()` BEFORE clearing `transcriptSink` — the other
  conversation's in-flight tail is persisted with nothing lost. Only then
  take over.
- **Mid-generation** → refuse (the composer is already disabled; this is a
  hard guard).

### Preamble (seeded-fallback)

`continuationPreamble(from:newMessage:maxTurns:maxBytes:)` — pure, tested:

- Projects `chat_messages` to `(role, text)` for user/assistant rows only.
  `.result` is **deduplicated** — it follows `.assistantText` with identical
  text for the same turn, so it's skipped when preceded by a matching
  `.assistantText`. A standalone `.result` (no preceding `.assistantText`) is
  kept.
- Last N turns (default 10), byte-capped (default 12 KB), oldest dropped first.
- Wrapped in "You are continuing an earlier conversation about this wiki…"
  header, followed by `--- new message ---` + the user's actual message.

### Display vs send (the preamble visibility fix)

The preamble is an internal instruction to the agent, not the user's message.
`sendInteractiveMessage` takes a `displayText` parameter: the preamble is sent
to the backend (`TurnInput.userText`), but the user's actual message is what
appears as the `.userText` event in the transcript (and what gets persisted to
`chat_messages`). `continueConversation` passes `firstMessage: preamble` +
`firstMessageDisplay: trimmed` (the user's actual message).

### Same-row append

The fresh session writes to the SAME chat row — `seq` continues, title is
preserved, `updatedAt` bumps it to the top of Recent. `activeChatID = chat.id`
flips `ConversationView` to live for this tab.

### Stale-onExit guard (load-bearing)

D3's takeover (`stopAgent` → `startInteractiveQuery`) lets the old session's
`onExit` fire AFTER the new session starts. `onExit` was guarded only on
`isRunning`, so the stale `onExit` would tear down the new "continue" session.
Added a per-session `currentRunToken: UUID?` — `onExit` captures the token at
start and only calls `finish` if it's still current (`run()` +
`startInteractiveQuery` both guarded). Tests can't catch this (no real
processes); the full suite confirms behavior-preserving.

## Sidebar affordances (pillar 4)

`AgentToolsView` sidebar:

- **+ New Conversation** menu on the Recent Conversations header (Ask default,
  Edit) → `store.openTab(.ask/.edit)` (draft state).
- **Live indicator** — tinted `circle.fill` + "responding…" caption when the
  matching launcher (`askLauncher` for `.ask`, `editLauncher` for `.edit`)
  has `activeChatID == chat.id` AND `isGenerating`. Pure `isLiveRow(...)`
  predicate (unit-tested).
- **Rename Conversation…** context menu → `.alert` + `TextField` →
  `store.renameChat(id:to:)`.
- **Ask/Edit subtitles** — "New read-only conversation" / "New editing
  conversation".
- List stays most-recently-updated-first.
- The Recent Conversations section (header + rows) is gated on
  `!store.chats.isEmpty` — it appears after the first conversation is saved.

## Files

| Area | File | Role |
| --- | --- | --- |
| Core | `WikiRenderContext.swift` (new) | Pure render precompute + closures |
| Core | `ChatModels.swift` (new) | `ChatKind`, `ChatSummary`, `ChatMessage`, `isPersistable`, `chatRole` |
| Core | `SQLiteWikiStore.swift` | v25 `chats` + `chat_messages` (fresh + ladder), chat CRUD |
| Core | `WikiStore.swift` | protocol: create/list/append/messages/rename/delete |
| Core | `WikiStoreModel.swift` | `chats` state, `renderContext()` memo + bus invalidation, `retargetTab` |
| Core | `WikiSelection.swift` | `.chat(PageID)` |
| Core | `AgentEvent.swift` | `Codable`, `isPersistable`, `endsGeneration` (turn-boundary) |
| App | `AgentBackend.swift` (new) | `protocol AgentBackend`, `BackendProfile`, `CLIProfile`, `SessionHandle`, `TurnInput` |
| App | `ClaudeCLIBackend.swift` (new) | actor: spawn/parse/encode, per-turn `AsyncStream`, pipe bridge |
| App | `AgentLauncher.swift` | `activeChatID`, `currentRunToken`, backend consumption, transcript sink/flush |
| App | `AgentOperationRunner.swift` | `startQueryConversation`, `continueConversation`, `continuationPreamble`, takeover predicate |
| App | `ConversationView.swift` (new) | unified surface (absorbs `QueryConversationView` body + `ChatHistoryDetailView`) |
| App | `AgentTranscriptWebView.swift` | context param, `isFinal` tiering, `BlobSchemeHandler` |
| App | `AgentToolsView.swift` | recent-conversations list, rename, live badge, `+` |
| App | `WikiDetailView.swift` | `.chat` → `ConversationView` |
| Tests | `ChatStoreTests`, `ChatPersistenceTests`, `ConversationViewD2Tests`, `ConversationContinueD3Tests`, `AgentToolsD4Tests`, `WikiRenderContextTests`, `AgentTranscriptLinkifyTests`, `FreshSchemaParityTests` (+ extensions) |

## What's deferred

- **Phase B — session resume (`backend.resume` / `--resume`):** the CLI
  backend stubs `resume` nil; seeded-fallback continue is the working path.
  Resume is a backend capability contingent on choosing a backend that
  supports it (Polytoken/ACP). `claude --resume` pins the model —
  model-switching on resume is a backend capability, not a given.
- **D5 — per-mode `BackendProfile` profiles:** Ask and Edit can run different
  models/providers via named agent profiles. Not part of the conversation-ui
  core phases.
- **v24 merge — `source_markdown_versions.content` DROP COLUMN:** main's v24
  drops the dead inline content column. This branch still has it (harmless —
  writes set it to `''`). Will be merged from main separately.
- **`[[chat:…]]` wikilinks, quote anchors into chats, `chats.jsonl`, File
  Provider `chats/` tree.**
- **Multiple concurrent live sessions per kind** (needs a per-conversation
  launcher pool; D3's takeover semantics are designed so the pool slots in
  without changing the conversation surface).
