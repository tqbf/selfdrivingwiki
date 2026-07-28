---
timestamp: 2026-07-18T193931Z
title: "Tantivy Phase 2 — Cutover (feature/tantivy-search-cutover)"
branch: null
status: historical
timestamp_source: git-commit
---

# Tantivy Phase 2 — Cutover (feature/tantivy-search-cutover)

## Progress


**Date:** 2026-07-18

Phase 2 makes Tantivy the **primary BM25 leg** of the hybrid search (BM25 +
sqlite-vec cosine + `RankFusion.rrf`), with FTS5 kept as fallback. Phase 1's
shadow index (#574) is already merged; this wires it into the real search path.

**Design: Option B — `bm25Leg` injection seam.** Rather than expose the store's
private FTS/Semantic leg methods and move RRF into the model (6 new protocol
methods + duplicate fusion logic), the proven in-store RRF path is kept
unchanged. The 3 `WikiStore.searchSimilar*` methods gain an optional
`bm25Leg:[Summary]?` parameter. When non-nil/non-empty, the store uses it
INSTEAD of running FTS5, then fuses with the semantic cosine leg via RRF
exactly as today. When nil/empty, it runs FTS5 (legacy path).

**Changes:**
- `TantivyShadowSearchResult.ulid` — computed property deriving the raw ULID
  from the composite `"<kind>:<ULID>"` documentID, enabling catalog resolution.
- `WikiStore` protocol: `searchSimilar`/`searchSimilarSources`/
  `searchSimilarChats` gain `bm25Leg` (no default — protocol requirements can't
  carry defaults); a `public` extension provides the 2-arg legacy entry points
  (zero caller breakage for wikictl, tests, and the model's sync wrappers).
- `GRDBWikiStore` + `SQLiteWikiStore`: when `bm25Leg` is supplied, use it as
  the FTS rows; otherwise run FTS5. Semantic leg + `RankFusion.rrf` unchanged.
- `WikiStoreModel`: `tantivySearch` property (injected post-init by
  `WikiSession`, same lifecycle as `readPool`). The 3 debounced search methods
  (pages/sources/chats) call `resolveTantivyLeg(query:kind:limit:catalog:)`,
  which queries the Tantivy actor, maps hits → full typed summaries via the
  cached catalog ([summaries]/[sources]/[chats]), and preserves Tantivy's
  best-first rank. `logShadowComparison` logs BM25/fused overlap + latency.
- `WikiSession.searchTantivy(query:kinds:limit:)` — public accessor for raw
  Tantivy hits (returns nil when the index is unavailable, not an empty list,
  so callers can distinguish "fall back to FTS5" from "no matches").

**FTS5 is fully intact** — Phase 3 (retire FTS5 + sqlite-vec) is the next step.

**Tests:** `TantivyBM25LegCutoverTests` (6 tests, fast tier) — verifies the leg
is used when supplied (membership + rank order preserved), nil/empty fall back
to FTS5, and the default-arg (2-arg) path is the legacy behavior. Full fast
tier (2558 tests) passes.

**Build:** `make version prompts` + `swift build` clean (no warnings under
`-warnings-as-errors`).

## Verification

Historical verification remains in the progress record above.
