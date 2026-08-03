---
timestamp: 2026-07-16T032543Z
title: "#163 — Drop routing for .webloc / remote URLs (2026-07-05)"
branch: null
status: historical
timestamp_source: git-commit
---

# #163 — Drop routing for .webloc / remote URLs (2026-07-05)

## Progress


**Problem:** dragging a `.webloc` file or an `http(s)` URL from a browser onto
the window hit the generic file-drop path (`addFiles`), ingesting the
`.webloc` plist's raw bytes instead of fetching the linked page.

**Fix**
- `WikiStoreModel.addDroppedURLs(_:fetcher:)` — partitions dropped URLs:
  `http(s)` URLs and `.webloc` shortcuts (resolved to their target) route through
  `addURL` (the "Add from URL" fetch + HTML→Markdown path); other `file://`
  URLs still ingest as raw bytes via `addFiles`. Supports multi-URL drops;
  an unresolvable `.webloc` is skipped (its bytes aren't a useful source).
  Named `add*` (not `ingest*`) since it only adds a source — agent ingestion
  (read source → generate pages) is a separate `AgentLauncher` phase.
- `WikiStoreModel.resolveWeblocURL(_:)` — reads the plist (XML or binary) off the
  main actor via `PropertyListSerialization`.
- `ContentView` `.dropDestination` now calls `store.addDroppedURLs(_:)`.

**Tests:** `WikiStoreModelDropRoutingTests` (5) — webloc→md, http url→md, local
txt→verbatim, mixed batch, unresolvable webloc skipped. All pass; existing
`WikiStoreModelAddURLTests` still green.

## Verification

Historical verification remains in the progress record above.
