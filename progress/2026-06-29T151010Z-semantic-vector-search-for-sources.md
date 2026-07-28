---
timestamp: 2026-06-29T151010Z
title: "2026-06-28 — Semantic (vector) search for sources"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-28 — Semantic (vector) search for sources

## Progress


Added meaning-based search over sources, mirroring the existing page-embedding
pipeline (sqlite-vec cosine + Apple `NLEmbedding`) verbatim on a new per-source
embeddings table. Surfaced in the Sources sidebar search box and via a new
`wikictl source search` command so the agent finds source material by meaning.
See [`plans/source-semantic-search.md`](plans/source-semantic-search.md).

**Phase 1 — storage & embeddings (`SQLiteWikiStore` / `WikiStore`):**
- **v11 → v12 migration:** new `source_embeddings(source_id PK → sources(id) ON
  DELETE CASCADE, embedding BLOB)` table, mirroring `page_embeddings` (v7).
- `storeSourceEmbedding(id:blob:)`, `searchSimilarSources(query:limit:)`
  (cosine ranking with a `LIKE` filename/display-name fallback), and
  `recomputeMissingSourceEmbeddings() -> Int` (backfills gaps; embeds on
  processed-markdown HEAD body + name, name-only when no markdown). All three
  added to the `WikiStore` protocol (only `SQLiteWikiStore` conforms).
- **Re-embed hooks** keep embeddings fresh: `reembedSource(sourceID:body:)` is
  called from `appendProcessedMarkdown` (covers extraction seeding, raw-text
  seeding, user edits, and revert) and `renameSource` (title changed).
  Best-effort (`try?`); falls back to reindex backfill when vec is unavailable.
- `searchSimilarSources` enumerates the 11 source columns explicitly — **never
  `SELECT s.*`** (the physical `sources` table has a `content` BLOB between
  `byte_size` and `created_at` that would shift `sourceSummary(from:)`'s indices).

**Phase 2 — model & UI:** `WikiStoreModel` gained `sourceSearchQuery` +
`sourceSearchResults` + a debounced (300 ms) `scheduleSourceSearch`. A Sources
search bar (mirroring the Pages `searchBar`) sits between the filter picker and
the rows, swapping to ranked results with a "No matching sources" empty state.
`recomputeMissingSourceEmbeddings()` on the model first seeds markdown-native
sources (so they get *content* embeddings) then calls the store recompute.
"Reindex Search" now also runs the source recompute.

**Phase 3 — agent CLI + system prompt:** `source search --query "…" [--limit N]`
prints ranked `id<TAB>name` lines (display name, filename fallback), read-only
(mirrors `PageCommand.search`). `--limit` validated 1–100 (default 10). Added to
`ArgumentParser.usageText` and the `SystemPrompt.swift` tooling list, with a note
that source *content* is searchable (complementing `sources.jsonl` metadata and
`source cat` raw bytes).

**Tests:** new `SourceEmbeddingSearchTests` (17 tests) covering the v12
migration, the LIKE fallback (find/limit/display-name/empty/no-`SELECT *`
regression), recompute/re-embed no-op behavior without vec, the `ON DELETE
CASCADE`, and the CLI TSV output + arg validation. The model-gated cosine path
cannot run under `swift test` (NLEmbedding is app-bundle-gated) — same limitation
as page search; AC.1/AC.3/AC.6 validated manually in the running app. Updated
schema-version assertions (11 → 12) across 6 existing tests. **1189 tests green.**

Branch `feature/source-semantic-search`.

## Verification

Historical verification remains in the progress record above.
