---
timestamp: 2026-09-09T062111Z
title: Queue Overview Inputs/Outputs sections for ingestion jobs
branch: feature/integrated-queue-workspace
status: complete
---

# Queue Overview Inputs/Outputs sections for ingestion jobs

## Progress

Operator request: an ingestion job's Overview now renders two labeled
sections — "Inputs" (the existing payload inventory rows, renamed) and
"Outputs" (the pages produced from those inputs).

**Outputs come only from recorded store evidence.** The new read-only store
API `pagesCitingSources(sourceIDs:limit:)` (declared on `WikiStore`,
implemented in `GRDBWikiStore`, threaded through a THROWING
`WikiStoreModel` wrapper) returns the distinct pages whose
`page_version_sources` citation edges cite the job's input sources — the
inverse of `sourceReferencingPageVersions`, walking the same edges
`provenanceDeletionBlockers` uses. Job success, agent exit, and merge
completion are never consulted. A resolved zero ("Outputs (0)") is store
evidence; loading/failure states have NO count (unknown ≠ zero).

Design decisions:
- Titles resolve through the live-title seam: the store query LEFT JOINs
  `pages` (the same table `summaries` feeds `QueueTargetNameIndex` from);
  the mapper prefers the name index's live title, falls back to the
  recorded store title, then degrades to "Deleted page". Only pages that
  resolve through the live seam get the Open Page name link (same
  membership rule as inventory `rowActions`) — no dead links.
- `CitedPage` (pageID + nullable current title) lives in
  `WikiFSTypes/PageVersionSource.swift` beside the rest of the
  provenance vocabulary.
- The Outputs section renders as a second `Section` inside the SAME
  inventory `List` (one scroll region; input rows, search, and Run Details
  untouched). Header reuses the outer header style via
  `QueueWorkspaceMapper.outputsSectionTitle`.
- The load runs in a `.task(id: itemID|attempt)` in `ActivityWindowView`
  (same posture as the report load; bounded by the new
  `QueueWorkspaceMetrics.Outputs.maxRows` = 200). Store-read failure logs
  via `DebugLog.store` and shows an honest "couldn't be loaded" state —
  never a fabricated zero.
- Lint and extraction Overviews are untouched (`outputs: nil`); ingest's
  section noun changed "Sources" → "Inputs" in `sectionTitle`.

## Verification

- `swift test --filter PagesCitingSourcesTests` — 8/8 passed (distinct
  pages, case-insensitive title order, LIMIT, duplicate args, cascade
  deletion drops the output).
- `WIKIFS_APP_TESTS=1 swift test --filter QueueOutputsMappingTests` —
  7/7 passed (loading/failed/empty/some/deleted/recorded-fallback/section
  nouns).
- `WIKIFS_APP_TESTS=1 swift test --filter
  ingestionOverviewShowsOutputsSectionWithClickableRows` — passed (real
  GRDB citations → real API → real hosted view; 3 name links; clicks route
  1× Open Page + 2× Reveal Source; vanished page hosts no button).
- Focused queue suites passed: QueueWorkspacePresentationTests,
  QueueWorkspaceIntegrationTests, QueueIngestionTests, QueueJobFilterTests,
  QueueActivityTracker* suites, QueueWindowRestorationManifestTests,
  QueueEngineHotSwapTests (7), LocalQueueRuntimeControllerTests (12).
- `make build` — app built + signed.
- Known pre-existing, reproduced on the clean tree (NOT from this change):
  `QueueEngineClientConformanceTests.allProtocolMethodsAreCallable` fails
  with `.notStarted` in this sandbox, and two hosted AppKit tests run in
  ONE process die silently after the first passes (each passes
  individually; verified by stashing this change).
