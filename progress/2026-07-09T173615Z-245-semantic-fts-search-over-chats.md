---
timestamp: 2026-07-09T173615Z
title: "2026-07-09 — #245: Semantic + FTS search over chats"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #245: Semantic + FTS search over chats

## Progress


Past Ask/Edit conversations are now searchable by meaning + keywords, mirroring
the existing pages/sources pipeline. Design of record:
`plans/chat-semantic-search.md`.

**Schema v28** (purely additive, `createChatSearchTables()` shared by the
fresh-schema fast path + the v27→28 ladder step; `freshFastPathMatchesStepwiseLadder`
holds): `chat_chunks` (per-chunk cosine embeddings, mirrors `page_chunks`/
`source_chunks`, FK `ON DELETE CASCADE` to `chats`), `chat_search` (one-row FTS
sidecar — title + concatenated message text, mirrors `source_search`), and
`chats_fts` (FTS5 external-content over `chat_search` with AFTER INSERT/UPDATE/
DELETE triggers). `deleteChat` cascades to all three — no extra code.

**Incremental write-time embedding (the key decision).** Chats are append-only
and grow over a session, so unlike pages/sources (re-chunk the whole document on
content change), a chat append embeds **only the new user/assistant messages**
and appends their chunks — never re-embedding prior turns. `reembedChatMessages`
runs outside the insert transaction (inference must not happen in a tx) inside
`mutate()`; `appendChatChunks` finds `MAX(chunk_idx)` and inserts after it
without deleting. Tool/system chatter is excluded from the semantic index (noise
for "what was discussed") but stays in the FTS body. `upsertChatSearch` rebuilds
the FTS sidecar inside the append tx + on rename. Best-effort (no-op when vec/
model unavailable).

**Self-heal + bulk backfill.** `ensureSearchIndexesPopulated` gains a
`chat_search` backfill step + a `chats_fts` `_idx` health-check; the debug log
line now reports `chats_fts`/`chatChunks` counts. `ensureEmbedderConsistency`
wipes `chat_chunks` on an embedder-model mismatch. `missingChatEmbeddingWork`
feeds a third `upgradeSearchIndex` phase (`SearchUpgradeState.Phase.chats`;
sheet reads "Embedding chats…"); `storeChatChunks` (replace-all) is the bulk path.

**Search.** `searchSimilarChats` → `hybridSearch` (the single RRF fusion flow),
FTS5 (`searchChatsFTS`) + vec0 cosine (`searchChatsSemantic`, best-matching chunk
per chat), `[ChatSummary]`, FTS-only fallback. Added to the `WikiStore` protocol
+ `WikiStoreModel` wrapper.

**Surfaces.** Chats sidebar search bar (`AgentToolsView`, debounced, off-main
reader-pool path, empty-state "No matching conversations"). `wikictl chat search
--query X [--limit N]` (TSV output) + system-prompt doc.

**Files:** `SQLiteWikiStore.swift`, `WikiStore.swift`, `WikiStoreModel.swift`,
`AgentToolsView.swift`, `SearchUpgradeView.swift`, `ChatCommand.swift`,
`ArgumentParser.swift`; new `ChatSearchTests.swift` (FTS backbone + chunk
mechanics + CLI). Schema-version assertions bumped 27→28 across the suite;
`storeChatChunks` added to `StoreEmissionExhaustivenessTests` noEmit; new chat
search tables added to `FreshSchemaParityTests` expected set.

## Verification

Historical verification remains in the progress record above.
