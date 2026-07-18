## Design: Tantivy search sidecar (#526)

Closes #526.

### What this PR adds

`plans/tantivy-search-sidecar.md` — a design research document evaluating whether
to replace the current FTS5 + sqlite-vec + RRF hybrid search with a Tantivy-backed
search sidecar via [botisan-ai/tantivy.swift](https://github.com/botisan-ai/tantivy.swift).

Also adds an entry for the new doc to the `PLAN.md` documentation index.

### Summary of findings

**Recommendation: Adopt Tantivy in 4 phases (build spike -> shadow index ->
cutover -> retire FTS5+sqlite-vec), gated on a Phase 0 build spike.**

Key design decisions:
- **One unified index** with a `kind` facet field (page/source/chat) -- enables
  cross-kind omnibox search and faceted filtering
- **Embeddings stay in SQLite** -- Tantivy has no ANN; sqlite-vec cosine is
  orthogonal to BM25. The RRF fusion layer stays, fusing Tantivy BM25 + cosine
- **Event bus sync** -- the Tantivy indexer subscribes to `WikiEventBus` for
  incremental add/update/delete via the existing `mutate()` seam
- **SQLite is always source of truth** -- the Tantivy index is a derived
  artifact rebuilt from the DB on corruption/first launch
- **Lives in `WikiFSSearch`** module (already extracted in #532)
- **Complementary with GRDB (#530)** -- Tantivy removes FTS5/vec from the store,
  simplifying the GRDB migration

### Risks identified (top 3)

1. **XCFramework must resolve in bare `swift build`** -- the package ships
   pre-built XCFrameworks; must verify macOS aarch64 slice exists (Phase 0)
2. **No documented snippet/highlight API** in tantivy.swift README --
   passage-level results may need client-side highlighting fallback
3. **aarch64-apple-darwin only** -- acceptable since the app already requires
   Apple Silicon (MLX), but should be documented

### What is NOT in this PR

No code changes. This is design research only -- the document covers build
integration, schema design, sync architecture, search API replacement,
fallback strategy, performance, and interaction with module restructuring and
GRDB adoption.
