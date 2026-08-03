# Chat semantic search (issue #245)

**Status: shipped.** Past Ask/Edit conversations are now semantically + lexically
searchable, mirroring the existing pages/sources search pipeline. A search field
in the Chats sidebar and `wikictl chat search` surface it.

## Goal

Chat content is prose — people remember *roughly what they discussed*, not exact
wording — so full semantic search (not just substring) is worth it. Chats already
persist (`chats` + `chat_messages`, v25) but had no search. Pages and sources
already had the exact pipeline this needed; this points it at chats.

## Schema (v28)

Purely additive — three new objects, mirroring the source search tables (chats,
like sources, have a multi-row body spread across `chat_messages`, so they use a
sidecar rather than the inline-`pages` external-content pattern):

```sql
-- Per-chunk cosine embeddings (mirrors page_chunks / source_chunks).
CREATE TABLE chat_chunks (
    chat_id   TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    chunk_idx INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    PRIMARY KEY (chat_id, chunk_idx)
) WITHOUT ROWID;

-- One row per chat: title + concatenated message text (mirrors source_search).
CREATE TABLE chat_search (
    chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
    title   TEXT NOT NULL,
    body    TEXT NOT NULL
);

-- FTS5/BM25 external-content over chat_search (mirrors sources_fts).
CREATE VIRTUAL TABLE chats_fts USING fts5(
    title, body, content='chat_search', content_rowid='rowid', tokenize='porter');
-- + AFTER INSERT/UPDATE/DELETE triggers (chats_fts_ai / _ad / _au).
```

Created by `createChatSearchTables()` (shared by the fresh-schema fast path and
the v27→28 migration step, so `freshFastPathMatchesStepwiseLadder` holds). A
`deleteChat` cascades to its `chat_chunks` + `chat_search` rows (FK ON DELETE
CASCADE) — no extra code.

## Write-time maintenance

### FTS sidecar (lexical)

`upsertChatSearch(chatID:)` rebuilds the one-row sidecar (title +
`GROUP_CONCAT(message text)`). `INSERT OR REPLACE` fires the FTS triggers so
`chats_fts` stays in sync. Called from:
- **`appendChatMessages`** — inside the insert transaction (the sidecar never
  lags the rows).
- **`renameChat`** — so keyword search reflects the new title.

### Incremental re-embed (semantic) — the key design decision

Chats are **append-only and grow over a session**, so unlike pages/sources
(which re-chunk the whole document on every content change via `replaceChunks`),
a chat append embeds **only the newly-arrived messages** and appends their chunks
— it never re-embeds prior turns.

- `reembedChatMessages(chatID:events:)` — for each new `user`/`assistant`
  message (the "what was discussed" prose; tool/system chatter is excluded from
  the semantic index but stays in the FTS body), chunk + embed via
  `EmbeddingService.chunkedEmbeddings`, then `appendChatChunks`.
- `appendChatChunks(chatID:chunks:)` — finds `MAX(chunk_idx)` and inserts after
  it, **without deleting existing rows**. This is the incremental path (vs
  `replaceChunks`'s delete-then-insert).
- Runs **outside the message-insert transaction** (inference must not happen
  inside a transaction — the SQLite concurrency invariant), still inside
  `mutate()` so the chunk write is serialized with other store calls. Mirrors
  `reembedSource`.
- Best-effort: a no-op when vec/the model is unavailable (the version still
  commits; chunks fill in on the next search-index upgrade).

### Self-heal (open-time)

`ensureSearchIndexesPopulated` gains two steps (mirroring source backfill +
FTS health):
- **Step 2b** — backfill `chat_search` for any chat lacking a row (a chat created
  before v28, or one whose appends predate the sidecar).
- **Step 3** — rebuild `chats_fts` when its `_idx` term index is empty (the
  launch ranking-bug probe).

`ensureEmbedderConsistency` wipes `chat_chunks` (alongside `page_chunks`/
`source_chunks`) on an embedder-model mismatch so the async backfill re-embeds.

## Bulk backfill

`missingChatEmbeddingWork()` → chats with no `chat_chunks`, embeddable text =
title + user/assistant message prose. Wired into `WikiStoreModel.upgradeSearchIndex`
as a third phase (`SearchUpgradeState.Phase.chats`); the sheet now reads
"Embedding chats…" during it. `storeChatChunks(id:chunks:)` (replace-all via
`replaceChunks`) is the bulk write path — used only by the one-time upgrade;
incremental appends never delete.

## Search

`searchSimilarChats(query:limit:)` → `hybridSearch` (the single RRF fusion flow
shared by pages + sources), with `searchChatsFTS` (lexical, always runs) +
`searchChatsSemantic` (vec0 cosine over `chat_chunks`, best-matching chunk per
chat). Falls back to FTS-only when vec/the model is unavailable. Returns
`[ChatSummary]`. Added to the `WikiStore` protocol.

## UI

A compact search bar in the **Chats sidebar section** (`AgentToolsView`), bound
to `store.chatSearchQuery` (debounced 300ms, same off-main-reader-pool path as
the Pages/Sources search). The list shows `chatSearchResults` when the query is
non-empty, `store.chats` otherwise; an empty-state reads "No matching
conversations."

## wikictl

`wikictl chat search --query "<words>" [--limit N]` — hybrid search; TSV output
(`id <tab> title <tab> kind <tab> messages`), best match first. Documented in the
system prompt alongside `chat list`/`chat get`.

## Files

| Area | File | Role |
| --- | --- | --- |
| Core | `SQLiteWikiStore.swift` | v28 tables (fresh + ladder), `upsertChatSearch`, `reembedChatMessages`, `appendChatChunks`, `storeChatChunks`, `missingChatEmbeddingWork`, `searchSimilarChats`/`searchChatsFTS`/`searchChatsSemantic`, self-heal steps |
| Core | `WikiStore.swift` | protocol: `storeChatChunks`/`missingChatEmbeddingWork`/`searchSimilarChats` |
| Core | `WikiStoreModel.swift` | `chatSearchQuery`/`chatSearchResults`/`scheduleChatSearch`, `searchSimilarChats` wrapper, upgrade `.chats` phase |
| App | `AgentToolsView.swift` | Chats sidebar search bar + filtered list |
| App | `SearchUpgradeView.swift` | `.chats` phase label |
| CLI | `ChatCommand.swift` | `.search` action |
| CLI | `ArgumentParser.swift` | `chat search` parsing + usage |
| Tests | `ChatSearchTests.swift` | FTS backbone + chunk mechanics + CLI |
| Tests | `FreshSchemaParityTests.swift`, `StoreEmissionExhaustivenessTests.swift` | schema + emission partition |

## What's deferred

- **Per-turn result deep-linking.** Search surfaces the whole conversation (a
  `ChatSummary` → opens the chat). Jumping to the specific matching turn/message
  (a `#"quote"`-style anchor into a chat) is a follow-up.
- **Re-embed on edit of a persisted message.** Chats are append-only today
  (messages are never edited in place), so there is no edit-re-embed path. If
  message editing lands, the incremental append model extends cleanly (edit =
  delete that chat's chunks + re-embed the whole conversation once).
