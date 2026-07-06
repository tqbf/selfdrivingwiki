# Persisted chat history (issue #119, phase 1)

Issue #119 asks for two things plus a set of "additional requirements":

1. Agent conversations get their own area / stop being one-Ask-one-Edit
   singletons.
2. Conversations persist to the wiki's SQLite store and are browsable /
   reopenable — like a ChatGPT/Claude history sidebar.
3. (Additional) Conversations become a third first-class linkable resource:
   `[[chat:…]]` wikilinks, quote anchors, `chats.jsonl` indexes, and a
   `chats/` File Provider tree.

PR #198 (unmerged stopgap) contributed the "New Conversation" semantics: end
the interactive session (`stopAgent()` is a safe no-op when idle), clear the
transcript artifacts, never touch a non-query run streaming into the shared
launcher, never touch `extractionLog`/`extractionPID`.

**This phase ships item 2 + the New Conversation affordance from #198, plus
the stable ULID identity that everything in item 3 hangs off.** Item 3's
surfaces (links, anchors, indexes, projection) are follow-up phases — see
"Deferred" below.

## Design

### Storage (schema v23)

Two tables in the per-wiki SQLite store, following the `log` /
`bookmark_nodes` conventions (TEXT ULID PKs, REAL epoch timestamps,
`ON DELETE CASCADE`):

```sql
CREATE TABLE chats (
    id         TEXT PRIMARY KEY,      -- ULID, the stable resource identity (#119 item 1)
    kind       TEXT NOT NULL,         -- 'ask' | 'edit'
    title      TEXT NOT NULL,         -- auto-derived from the first user message
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
    text       TEXT NOT NULL DEFAULT '',  -- plainText projection (future FTS / quote anchors)
    created_at REAL NOT NULL
);
CREATE UNIQUE INDEX chat_messages_seq ON chat_messages(chat_id, seq);
```

- One row per **persistable** `AgentEvent` (`userText`, `assistantText`,
  `toolUse`, `toolResult`, `subagent`, `result`, `systemInit`). The
  stream-bookkeeping events (`assistantTextDelta`, `messageStop`, `raw`)
  are never persisted — deltas are already merged into their
  `.assistantText` row by the launcher before a flush happens.
- `event_json` keeps the full typed event so the history view renders with
  the exact same `AgentTranscriptWebView` pipeline as the live view.
  `text` is the `plainText` projection so future phases (FTS, `#"quote"`
  anchors) never need to parse JSON.
- `role` is derived from the event case; it exists for indexing/anchor
  decomposition, not for rendering.
- Fresh-path and ladder share `createChatTablesV23()`
  (`FreshSchemaParityTests.freshFastPathMatchesStepwiseLadder` enforces the
  two stay identical).

### Write path

- `AgentOperationRunner.startQueryConversation` creates the chat row at
  session start (title = first user message, elided) and installs a
  transcript sink on the launcher.
- `AgentLauncher` flushes not-yet-persisted events to the sink at every
  **turn boundary** (`.messageStop` / `.result`, the same
  `AgentEvent.endsGeneration` seam the edit lock uses) and once more in
  `finish()`. A `persistedEventCount` cursor makes flushes incremental and
  idempotent; streamed assistant rows are only flushed once final.
- The sink captures the `WikiStoreModel` **weakly**: if the user switches
  wikis mid-session the original model may be gone — persistence for the
  orphaned session degrades to a no-op instead of writing into the wrong
  wiki.

### Read path / UI

- `WikiSelection.chat(PageID)` — a persisted conversation is a first-class
  selection, so it gets tabs, history navigation, and drag/drop for free.
- `ChatHistoryDetailView` renders a persisted transcript read-only via the
  same `AgentTranscriptWebView` + the shared `[AgentEvent].transcriptVisible`
  filter the live view uses.
- The Agent sidebar section (`AgentToolsView`) lists recent conversations
  (most-recently-updated first) under the mode rows, with a Delete context
  menu. Selecting one opens its tab.
- `QueryConversationView` gains the #198 New Conversation button (visible
  whenever a query session is live or a transcript is visible): stops the
  session (final flush persists the tail), clears the visible transcript,
  and detaches the sink so the next send starts a fresh chat row.

### What stays a singleton (for now)

The live Ask/Edit surfaces remain the two shared launchers — one live
session per kind. Persisted history removes the *data loss*; multiple
concurrent live conversations require per-conversation launcher instances
and are deferred (see below). The `.ask`/`.edit` selection cases are
untouched.

## Deferred (follow-up phases)

- **`[[chat:…]]` wikilinks** — new `WikiLinkParser.LinkType.chat`,
  `resolveChatByName`, link rows through `replaceLinks`.
- **Quote anchors** — `AnchorBlock`-style decomposition over
  `chat_messages.text` (per-message blocks).
- **Indexes** — `chats.jsonl` + manifest entry in `IndexGenerators`,
  `listAllChatsOrderedByID` read helper.
- **File Provider projection** — `chats/by-id/`, `chats/by-title/` trees +
  `WikiFSContainerID` entries + working-set/change-token folding.
- **Multiple concurrent live conversations / dedicated conversation tab
  strip** — needs per-conversation `AgentLauncher` instances.
- **Resume a persisted conversation** — capture claude's `session_id` from
  the `system/init` event and respawn with `--resume`; schema gains a
  nullable column when this lands.

## Files touched (phase 1)

| Area | File | Change |
| --- | --- | --- |
| Core | `SQLiteWikiStore.swift` | v23 tables (fresh + ladder), chat CRUD |
| Core | `WikiStore.swift` | protocol: create/list/append/messages/rename/delete |
| Core | `ChatModels.swift` (new) | `ChatKind`, `ChatSummary`, `ChatMessage` |
| Core | `AgentEvent.swift` | `Codable`, `isPersistable`, `role` |
| Core | `WikiSelection.swift` | `.chat(PageID)` |
| Core | `EditorTab.swift` | tab title/icon for `.chat` |
| Core | `WikiStoreModel.swift` | `chats` state + wrappers, history pruning |
| App | `AgentLauncher.swift` | transcript sink, flush cursor, `startNewConversation()` |
| App | `AgentOperationRunner.swift` | chat creation + sink install |
| App | `QueryConversationView.swift` | New Conversation button |
| App | `QueryTranscriptView.swift` | share the visible-events filter |
| App | `ChatHistoryDetailView.swift` (new) | read-only transcript |
| App | `AgentToolsView.swift` | recent-conversations list |
| App | `WikiDetailView.swift` | `.chat` case |
| Tests | `ChatStoreTests.swift`, `AgentEventCodableTests.swift`, `ChatPersistenceLauncherTests.swift`, extensions to tab/selection tests |
