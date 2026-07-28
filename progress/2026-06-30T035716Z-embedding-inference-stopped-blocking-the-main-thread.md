---
timestamp: 2026-06-30T035716Z
title: "2026-06-29 — Embedding inference stopped blocking the main thread"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-29 — Embedding inference stopped blocking the main thread

## Progress


Clicking a page (and app startup) had a ~0.4–2 s stall introduced by the
semantic-search work (PR #91). Root-caused via `ReaderTiming`/`DebugLog`
instrumentation (subsystem `com.selfdrivingwiki.debug`, category `render`):

- The **page-row context menu** in `SidebarView.pagesSectionRows` eagerly called
  `store.searchSimilar(query:)` for every page row in its `.contextMenu` builder.
  SwiftUI evaluates that builder on every sidebar layout pass, so a single page
  selection ran `searchSimilar` (→ `NLEmbedding.vector(for:)` on the **main
  thread**) for all ~232 rows — hundreds of inferences per render, freezing the
  UI. (Sources were fast only because their rows lack that menu.)
- Separately, at launch `backfill` called `EmbeddingService.isAvailable`, which
  **loads the `NLEmbedding` model** (~0.3 s on the main thread) even when there
  was zero missing work to embed.

**Fixes (this branch):**
- `WikiStoreModel.searchSimilar` / `searchSimilarSources` are **no-ops (`[]`)**
  until NLEmbedding inference is moved off the main actor; the "Find Similar…"
  context-menu item is removed.
- `backfill` now short-circuits on empty work **before** touching the embedding
  model, so a warm DB skips the model load at startup.
- `EmbeddingService` is instrumented end-to-end (`embed.model LOAD`, `embed.isAvailable`,
  `embed.chunked ENTER/EXIT`, `embed.call <ms> …`, `embed.STACK …`) so every hit
  is visible via `log show`. Kept as witness marks.
- Reader timing probes added: `click.to-startLoad`, `click.to-painted`,
  `webview.main-hop`, `webview.task-start`, `webview.html-load`.

**Follow-up (not done here):** move `NLEmbedding` inference off the main actor
(the comment claims BNNS crashes off-main, but that's most likely a shared-model
concurrency issue — serialize on a dedicated background thread) and restore
"Find Similar" with a lazy, off-main search.

## Verification

Historical verification remains in the progress record above.
