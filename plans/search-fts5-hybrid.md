# FTS5/BM25 + hybrid (vec + BM25) search

> **Status:** ✅ All three phases done (FTS5/BM25 + static sqlite-vec + RRF hybrid
> reranker). Search works end-to-end. Build is fully repeatable: vec is vendored as
> the `sqlite-vec.c` amalgamation (`Sources/CSqliteVec/`, `-DSQLITE_CORE`),
> `swift build`/`make` Just Works — no dylib, no load_extension.

## Goal

Make search actually work. Today it is either **broken** (the sqlite-vec semantic
layer never loads — macOS system SQLite is built with `SQLITE_OMIT_LOAD_EXTENSION`,
so `sqlite3_load_extension` / `sqlite3_enable_load_extension` don't exist and `dlsym`
returns NULL) or it degrades to **filename-only `LIKE`**. Neither path reads the
document body, so a query like `hypnosis` finds nothing.

This plan adds three things:

1. **FTS5/BM25 backbone** — always-on lexical search over the full body. FTS5 is
   *core* SQLite (`ENABLE_FTS5` verified on the system SQLite), so it needs no
   extension and no model; it works in `wikictl`, in `swift test`, and in the app.
2. **Fix vec** — the semantic layer, via a **static sqlite-vec amalgamation**
   (`-DSQLITE_CORE`, direct `sqlite3_vec_init`), since the loadable `.dylib` cannot
   be loaded against the system SQLite.
3. **RRF hybrid reranker** — fuse lexical (BM25) and semantic (cosine) results via
   Reciprocal Rank Fusion, so a doc matching *both* ranks above one matching either.

Verified facts grounding this plan:
- `PRAGMA compile_options` → `ENABLE_FTS5`, `OMIT_LOAD_EXTENSION` (system SQLite).
- `bm25()` + `MATCH 'hypnosis'` returns the matching row on the system SQLite.
- The running app logs: `loadVecExtension: dlsym FAILED … semantic search disabled`
  → `searchSimilarSources: … vec=false` → `LIKE FALLBACK (body NOT searched)`.
- `pages` and `sources` are normal **rowid** tables (no `WITHOUT ROWID`), so
  external-content FTS5 keyed on `rowid` works.

## Phase 1 — FTS5/BM25 backbone (no deps; fully unit-testable)

### Schema v12 → v13 (`SQLiteWikiStore.bootstrapSchema`, after the v12 block)

**Pages** — body (`body_markdown`) is inline on `pages`, so use **external-content
FTS5** over `pages` with triggers. This needs **zero changes to page-write Swift**
(triggers fire on existing `createPage`/`updatePage`/`deletePage` SQL):

```sql
CREATE VIRTUAL TABLE pages_fts USING fts5(
    title, body_markdown, content='pages', content_rowid='rowid');
CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
  INSERT INTO pages_fts(rowid,title,body_markdown) VALUES(new.rowid,new.title,new.body_markdown); END;
CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
  INSERT INTO pages_fts(pages_fts,rowid,title,body_markdown) VALUES('delete',old.rowid,old.title,old.body_markdown); END;
CREATE TRIGGER pages_fts_au AFTER UPDATE ON pages BEGIN
  INSERT INTO pages_fts(pages_fts,rowid,title,body_markdown) VALUES('delete',old.rowid,old.title,old.body_markdown);
  INSERT INTO pages_fts(rowid,title,body_markdown) VALUES(new.rowid,new.title,new.body_markdown); END;
```

**Sources** — body is the **HEAD of `source_markdown_versions`** (versioned), not
inline on `sources`, so use a small **sidecar** + external-content FTS5 over it:

```sql
CREATE TABLE source_search (
    source_id TEXT PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
    title     TEXT NOT NULL,
    body      TEXT NOT NULL);
CREATE VIRTUAL TABLE sources_fts USING fts5(
    title, body, content='source_search', content_rowid='rowid');
-- + pages_fts-style ai/ad/au triggers on source_search (columns title, body).
```

Backfill of *existing* content is done in the **Reindex** path (respects the
lazy-seeding convention): `INSERT INTO pages_fts(pages_fts) VALUES('rebuild');` and
populate `source_search` from HEAD versions, then rebuild `sources_fts`. New content
is indexed immediately via triggers/hooks.

### Store methods (`WikiFSCore`)

- `upsertSourceSearch(sourceID:title:body:)` — `INSERT OR REPLACE INTO source_search`
  (the trigger maintains `sources_fts`).
- `searchPagesFTS(query:limit:) -> [WikiPageSummary]` —
  `SELECT p.id,p.title,p.updated_at,p.created_at FROM pages_fts JOIN pages ON
  pages.rowid=pages_fts.rowid WHERE pages_fts MATCH ?1 ORDER BY rank LIMIT ?2`
  (sanitize the user query into an FTS5 MATCH expression).
- `searchSourcesFTS(query:limit:) -> [SourceSummary]` — join `sources_fts` →
  `source_search` → `sources` (explicit column list — never `SELECT s.*`, same trap
  as `searchSimilarSources`).
- `rebuildFTS() -> (pages:Int, sources:Int)` — rebuild both indexes; fill
  `source_search` gaps from HEAD versions first.

### Write hooks

- **Pages:** none — triggers on `pages` handle create/update/delete.
- **Sources:** in `appendProcessedMarkdown` (next to the existing `reembedSource`
  call) call `upsertSourceSearch(title, body: content)`; in `renameSource` call it
  with the new title + current head body.

### Search switch (Phase-1 shape; Phase 3 changes this to fuse)

- `searchSimilar`: vec available → semantic; **else FTS** (was `title LIKE`).
- `searchSimilarSources`: same.

## Phase 2 — fix vec (static sqlite-vec amalgamation)

- Vendor `sqlite-vec.c` into a SwiftPM **C target** (`CSqliteVec`) compiled with
  `-DSQLITE_CORE`. With `SQLITE_CORE`, the `SQLITE_EXTENSION_INIT1/2` macros are
  no-ops and sqlite-vec calls the system `sqlite3_*` symbols directly (they exist;
  only `load_extension` is omitted).
- Replace `ensureVecExtensionLoaded` / `loadVecExtension` (the dead `dlopen` +
  `dlsym` + `sqlite3_load_extension` path) with one per-connection call:
  `sqlite3_vec_init(db, &errmsg, NULL)` exposed through a tiny `CSqliteVec` wrapper.
- Drop `vec0.dylib` from the bundle + `build.sh` + the `Resources/vec0.dylib` copy.
- **Riskiest piece** — spike the C-target + sqlite3.h discovery before committing.

## Phase 3 — RRF hybrid reranker (pure Swift; fully unit-testable)

BM25 scores and cosine distance are incomparable, so fuse by **rank**:

```
RRF_score(d) = Σ_i  1 / (k + rank_i(d))      // k = 60 (standard)
```

- Generic `func fuseRRF<T: Identifiable>(_ lists: [[T]], k: Int = 60) -> [T]`
  (dedupe by id, sort by fused score desc, tie-break by best single rank).
- `searchSimilar` / `searchSimilarSources`:
  - vec available → fetch vec (top ~`2×limit`) **and** FTS (top ~`2×limit`) →
    `fuseRRF` → `limit`.
  - else → FTS-only.
- Naturally degrades: vec unavailable (model gated, CLI, tests) → FTS-only still works.

## Acceptance Criteria

- **AC.1** Exact body term with zero filename overlap returns the source/page (the
  `hypnosis` case) — FTS, works under `swift test`.
- **AC.2** Paraphrase query returns the relevant doc when vec is available (cosine).
- **AC.3** A doc ranking high in **both** vec and FTS ranks above one in only one (RRF).
- **AC.4** vec unavailable → search still returns results (FTS-only); never an empty
  nothing.
- **AC.5** Deleting a page/source removes its FTS row (trigger / FK cascade).
- **AC.6** `swift build` + `swift test` pass; FTS + RRF are unit-tested (not model-gated).

## Test Strategy

- **FTS** (runs under `swift test`, no app gating): index round-trip, `bm25` ranking,
  `MATCH` over body, delete cascade, zero-filename-overlap hit.
- **RRF** (pure Swift): hand-crafted rankings → assert fusion order + tie-breaks.
- **vec** (still app-gated): manual AC.2 via `DebugLog`/os_log in the running app.

## Risks

- External-content FTS5 trigger correctness — mitigated by reusing the canonical
  `delete`/`insert` trigger bodies and a `rebuild()` resync.
- `sqlite-vec.c` vendoring + SwiftPM C target + sqlite3.h discovery (Phase 2) — the
  riskiest piece; spike first, fall back to bundling a load-extension-enabled SQLite.
- RRF `k` (60) is standard and tunable later; no training data required.
