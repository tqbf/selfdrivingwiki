# Chat Summary (Issue #411)

## Goal

Show a one-line AI summary of the model's response under each chat row in the
sidebar (`RecentChatRow`). The summary is generated once on chat completion and
stored in the SQLite database.

## Strategy (v0)

**Deterministic extract first**, with LLM summarization as a future enhancement.

- On chat completion (terminal `.result` event), extract the first sentence of
  the first `.assistantText` or `.result` event, elided to ~60 chars using the
  existing `ChatSummary.title(fromFirstMessage:maxLength:)` elision rule.
- No LLM call needed for v0 — instant, no external dependency, no provider key
  required. The LLM path can be layered on top later via `AgentBackend`.
- This delivers the UI feature immediately and keeps the schema + store +
  rendering infrastructure in place for when LLM summarization is added.

## Implementation

### 1. Schema migration (v35 → v36)

Add `summary TEXT` and `summary_at REAL` columns to the `chats` table:

- New `migrateV35ToV36()` method: `ALTER TABLE chats ADD COLUMN summary TEXT;`
  + `ALTER TABLE chats ADD COLUMN summary_at REAL;` (simple ALTER — no table
  rebuild needed for nullable columns).
- Update `createChatTablesV23()` to include the new columns for fresh DBs.
- Bump `PRAGMA user_version=36`.
- Follow the `mutate(event:_:)` + `ResourceChangeEvent` pattern from the store
  emission invariant.

### 2. Model update (`ChatSummary`)

Add `summary: String?` and `summaryAt: Date?` to `ChatSummary` in
`Sources/WikiFSCore/ChatModels.swift`.

### 3. Store methods (`SQLiteWikiStore`)

- Update `listChats()` SELECT + `chatSummary(from:)` decoder to include the new
  columns.
- New public mutator: `updateChatSummary(chatID:summary:)` — writes the summary
  + timestamp, routes through `mutate(event:_:)`, emits `ResourceChangeEvent`.
- `StoreEmissionExhaustivenessTests` will enforce the new mutator is partitioned
  correctly.

### 4. `WikiStoreModel` wrapper

Add `updateChatSummary(chatID:summary:)` that delegates to the store, matching
the existing `renameChat(id:to:)` pattern.

### 5. Summarization hook (`AgentLauncher`)

After the terminal `.result` event is processed in the interactive session loop
(`AgentLauncher.swift` ~line 1819, after `flushTranscript()`), call a new
`generateChatSummary(for:)` method that:
- Collects the first `.assistantText` or `.result` event from `events`.
- Extracts the first sentence, elides to 60 chars via the existing elision rule.
- Call `store.updateChatSummary(chatID:summary:)`.

### 6. UI rendering (`RecentChatRow`)

In `Sources/WikiFS/AgentToolsView.swift`, update `RecentChatRow`:
- When not live and `chat.summary != nil`, show the summary as a `.caption`
  `.foregroundStyle(.secondary)` line under the title, replacing the timestamp.
- When live, keep the "responding…" indicator.
- When no summary, keep the relative timestamp.

### 7. Tests

- Store column round-trip (write summary, read it back via `listChats`).
- Store emission exhaustiveness (new mutator is partitioned).
- Deterministic extract produces a non-empty string.
- `RecentChatRow` shows summary when present (if testable).

### 8. Docs

Update `plans/chat-and-persistence.md` with the new `summary` column.
