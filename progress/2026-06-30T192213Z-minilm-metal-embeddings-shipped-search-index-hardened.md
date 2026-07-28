---
timestamp: 2026-06-30T192213Z
title: "2026-06-30 — MiniLM (Metal) embeddings shipped; search index hardened"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-30 — MiniLM (Metal) embeddings shipped; search index hardened

## Progress


- **MiniLM/MLX embeddings now run in the bundled app.** It had been crashing
  immediately on launch (a silent `exit()`): MLX couldn't find its `metallib` (it
  searches next to the binary, not via the bundle) and its default error handler
  `exit()`s. Fixed the bundle layout so MLX finds it, and moved `MLXEmbedders`
  off `WikiFSCore` so the File Provider extension no longer transitively links
  Metal.
- **Search ranking fixed.** The launch self-heal never rebuilt the FTS5 index for
  wikis migrated through the schema ladder — a `count(*)`-based health check is
  always satisfied for external-content FTS5 tables — so search degraded to
  semantic-only and ranked poorly. The check now detects an unbuilt index and
  rebuilds.
- **Embedding is a one-time, blocking, single-threaded upgrade** — no background
  "backfill." All `SQLiteWikiStore` access is main-thread only (a blocking modal
  sheet makes the upgrade the sole owner of the store); only MLX inference runs
  off-main. New content embeds inline at write time, so the upgrade is usually an
  instant no-op.
- **`searchSimilar` / "Find Similar…" restored** (it had been a no-op since the
  NLEmbedding main-thread freeze); MiniLM is cheap enough to run on demand.

## Verification

Historical verification remains in the progress record above.
