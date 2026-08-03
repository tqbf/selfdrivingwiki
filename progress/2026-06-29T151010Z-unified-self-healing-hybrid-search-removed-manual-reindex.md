---
timestamp: 2026-06-29T151010Z
title: "2026-06-29 — Unified, self-healing hybrid search (removed manual Reindex)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-29 — Unified, self-healing hybrid search (removed manual Reindex)

## Progress


**Bug:** source search returned **no results** in the app. Root cause: the live
DB (`01KVHRPBPRY368HJTZNSB75D7R`, 71 sources) had `source_search=0` and
`source_embeddings=0` rows — both halves of the hybrid query came back empty.
The only thing that populated these was the manual **"Reindex Search"** sidebar
button (`rebuildFTS` + `recomputeMissing*`), which was never run against
pre-existing sources. Verified via `DebugLog` + direct sqlite counts.

**Fix — one search flow that self-heals on every writable open:**
- **Unified the duplicated page/source search flow** into one generic
  `hybridSearch(kind:query:limit:id:fts:semantic:)` (FTS5 bm25 always; +vec0
  cosine fused via `RankFusion.rrf` when vec+model available; FTS-only fallback).
  Both `searchSimilar` and `searchSimilarSources` route through it — the two can
  no longer drift.
- **Unified embedding store + maintenance:** `storePageEmbedding`/
  `storeSourceEmbedding` → one generic `upsertEmbedding(table:idColumn:…)`; the
  two `recomputeMissing*` → one shared `embedMissing(kind:rows:store:)`.
- **Self-heal `ensureSearchIndexesPopulated()`** runs in `init(databaseURL:)`
  (writable only; NOT the read-only File Provider). Idempotent, near-zero cost
  when healthy: (1) seed native-markdown sources lacking a processed-markdown
  version, (2) backfill `source_search`, (3) rebuild `pages_fts`/`sources_fts`
  only when lagging, (4) `recomputeMissingEmbeddings` + `recomputeMissingSourceEmbeddings`.
- **Removed the manual reindex:** the sidebar "Reindex Search" button, and
  `recomputeMissingEmbeddings`/`recomputeMissingSourceEmbeddings`/`rebuildFTS`
  from the `WikiStore` protocol + `WikiStoreModel`. (Kept on the concrete
  `SQLiteWikiStore` — used by self-heal + tests.)

**Verified:** `swift build` clean; **1202 tests pass**. Against a snapshot copy
of the real DB, applying the FTS self-heal steps took `source_search` 0→71 and
`sources_fts` 0→71, and the bm25 query returned relevant hits for "dissociation"
and "hypnosis". (The embedding half can't run under raw sqlite3 — it needs
`NLEmbedding` — but is the same path covered by unit tests; it populates on the
app's next open.)

**Known, out of scope:** `wikictl` resolves the app-group container to
`group.org.sockpuppet.wiki` (empty) while the live data is in
`group.com.willsargent.wiki`, so `wikictl source search` can't reach the live DB
(`no wiki matching`). This is a pre-existing wikictl container mismatch, not a
search bug.

## Verification

Historical verification remains in the progress record above.
