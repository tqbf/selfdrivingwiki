---
timestamp: 2026-06-29T151010Z
title: "2026-06-28 — FTS5/BM25 keyword search (v13); vec layer found broken"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-28 — FTS5/BM25 keyword search (v13); vec layer found broken

## Progress


Discovered the **semantic (vec) search never actually ran in the app**: macOS's
system SQLite is built with `SQLITE_OMIT_LOAD_EXTENSION`, so
`sqlite3_enable_load_extension`/`sqlite3_load_extension` don't exist as symbols
→ `dlsym` returns NULL → `vec0.dylib` never loads → `isVecAvailable()` is always
false → every search (pages AND sources) degraded to filename-only `LIKE`. The
body was never indexed or searched. Confirmed via `DebugLog` instrumentation and
`PRAGMA compile_options` (`OMIT_LOAD_EXTENSION`; `ENABLE_FTS5` present).
See [`plans/search-fts5-hybrid.md`](plans/search-fts5-hybrid.md) (3-phase plan).

**Phase 1 done — FTS5/BM25 backbone (always-on, fully unit-testable):**
- **v12 → v13 migration:** `pages_fts` = external-content FTS5 over `pages`
  (`title`, `body_markdown`) maintained by AFTER INSERT/UPDATE/DELETE triggers
  (zero page-write Swift changes); `sources_fts` = external-content FTS5 over a
  new `source_search(source_id PK → sources(id) ON DELETE CASCADE, title, body)`
  sidecar (body is the HEAD of the version chain, not inline). Porter tokenizer
  (stemming: `run`↔`running`, `car`↔`cars`). Existing content backfilled lazily
  via `rebuildFTS()` (Reindex).
- **Store methods:** `searchPagesFTS`/`searchSourcesFTS` (bm25, `ORDER BY rank`),
  `upsertSourceSearch(sourceID:body:)` (resolves `display_name ?? filename`),
  `rebuildFTS() -> (pages, sources)`. Added to the `WikiStore` protocol + model.
- **Write hooks:** `addSource` (name-only), `appendProcessedMarkdown`,
  `renameSource` now keep `source_search` fresh (triggers keep `*_fts` in sync).
- **Search switch:** the `LIKE` fallback in `searchSimilar`/`searchSimilarSources`
  is now **FTS5 bm25 over the full body** (kept as the path taken when vec is
  unavailable — i.e. today, and in tests/`wikictl`).
- **Tests:** new `FullTextSearchTests` (body search with zero filename overlap,
  porter stemming, name-only, bm25 ranking, delete cascade, rebuild). All pass.
  Existing source-search tests now exercise FTS and still pass.
- **Phase 2 done — vec fixed via static amalgamation:** the loadable-`dylib` path
  was impossible on macOS (`OMIT_LOAD_EXTENSION`). Vendored `sqlite-vec.c`
  v0.1.9 into a new `CSqliteVec` SwiftPM C target (`Sources/CSqliteVec/`, +MIT
  license + provenance README) compiled `-DSQLITE_CORE -DSQLITE_VEC_STATIC`,
  linked against the **system** libsqlite3 (no second SQLite, no
  `load_extension`). Registered per-connection via the sqlite-vec C/C++ guide's
  "direct call" pattern — `sqlite3_vec_init(db, NULL, NULL)` — exposed as
  `wikifs_vec_register` and called from both inits. Removed the dead
  `dlopen`/`dlsym`/`load_extension` loader, the `vec0.dylib` copy in `build.sh`,
  and `Resources/vec0.dylib` itself — `make`/`swift build` now Just Works for any
  contributor (no dylib, no env vars). Proven by
  `vecScalarIsRegisteredAfterStaticLink` (vec_distance_cosine registers under
  `swift test` now); full suite green (1197 tests).
- **Phase 3 done — RRF hybrid reranker:** `RankFusion.rrf` (pure Swift,
  `Sources/WikiFSCore/RankFusion.swift`) fuses the semantic + FTS result lists by
  Reciprocal Rank Fusion (`score = Σ 1/(60+rank)`). `searchSimilar` /
  `searchSimilarSources` now always compute FTS5 (the lexical floor), and when vec
  + the embedding model are available also run the cosine query and fuse — a doc
  matching BOTH lexical + semantic outranks one matching only one. Degrades to
  FTS-only when vec/the model is unavailable (tests, `wikictl`). Fully unit-tested
  (`RankFusionTests`); full suite green (1202 tests). **Search now works end-to-end.**

## Verification

Historical verification remains in the progress record above.
