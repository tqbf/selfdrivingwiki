---
timestamp: 2026-07-16T211752Z
title: "2026-07-16 — Fix #477: wiki open blocking on large wikis (branch `fix/477-wiki-open-blocking`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — Fix #477: wiki open blocking on large wikis (branch `fix/477-wiki-open-blocking`)

## Progress


**Implemented.** Eliminated the frozen "Opening wiki…" spinner when opening
wikis with 300+ pages. Three changes address the synchronous main-thread
blocking at different layers of the session-resolution path:

1. **Persist link-reconcile flag in SQLite metadata (v37 migration)** —
   highest impact. Added a `wiki_metadata` key-value table (schema v37
   migration). `WikiStoreModel.upgradeSearchIndex` now checks a persisted
   `link_reconcile_version` key instead of an in-memory `didReconcileLinks`
   boolean that reset every model recreation. Previously,
   `LinkReconciler.reconcileAll` ran on every wiki open — 600+ synchronous
   SQLite read+write ops per page for 300 pages. Now it runs once per
   resolver version (currently `"1"`) and the flag persists across launches.
   `getMetadata`/`setMetadata` added to `WikiStore` protocol + `SQLiteWikiStore`
   (NO_EMIT, routes through `mutate(event: { _ in nil })`).

2. **Skip 10K-row log scan when all sources are marked** (issue #477 §2).
   `reloadSources()` now short-circuits `recentLogEntries(limit: 10_000)`
   when there are no un-marked sources (the common case — every source has
   `ingested_at` stamped). Avoids materializing 10K `LogEntry` structs just
   to filter them for the legacy ingest-status fallback.

3. **Task-wrap session resolution so spinner animates** (issue #477 §3).
   `RootScene.resolveSession(for:)` now runs in a `Task` with an initial
   `Task.yield()`, so the `ProgressView("Opening wiki…")` spinner paints and
   animates before the synchronous store init + model reloads execute. With
   fixes 1+2, the remaining init is ~4 lightweight SELECTs + one system-prompt
   read — single-digit ms even for 300+ pages.

**Files (6 changed):**
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — v37 migration (`wiki_metadata`
  table), `getMetadata`/`setMetadata` methods, `createWikiMetadataTable`/
  `migrateV36ToV37` (fresh schema + stepwise ladder)
- `Sources/WikiFSCore/WikiStore.swift` — `getMetadata`/`setMetadata` on the
  protocol
- `Sources/WikiFSCore/WikiStoreModel.swift` — replaced `didReconcileLinks`
  with persisted metadata check; `reloadSources` 10K-scan guard
- `Sources/WikiFS/RootScene.swift` — `resolveSession(for:)` Task-wrapped
- `Tests/WikiFSTests/StoreEmissionExhaustivenessTests.swift` — `setMetadata`
  classified NO_EMIT
- `Tests/WikiFSTests/WikiMetadataTests.swift` (new, 7 tests)

**Gates:** `swift build` clean; fast tier 2415 tests pass; `StoreEmissionTests`
partition check passes; `FreshSchemaParityTests` v37 schema matches; 7 new
`WikiMetadataTests` pass. PR #478.

## Verification

Historical verification remains in the progress record above.
