---
timestamp: 2026-10-04T150500Z
title: Source to running job navigation
branch: feature/source-running-job-link
status: complete
---

# Source to running job navigation

## Progress

The operator asked for a way to go from a source directly to its running
extraction or ingestion job. The app already had the seam: the tracker's
`pendingSelectionItemID` makes the Activity window open focused on one job
(#837 lint, #842 transcription). This work generalizes that seam to both
lanes and adds the source-side affordances.

Tracker (`QueueActivityTracker`):

- New `runningItemID(for:queue:)` resolves a source to its in-flight item.
  The lookup filters by lane through `itemToQueue`, so a source active in
  both lanes resolves each lane to its own item. Legacy `.transcription`
  items match the extraction lane via `canonical`.
- New `stagePendingSelectionForRunningJob(of:queue:)` sets the pending
  selection and returns the item ID. A miss returns nil and leaves the seam
  untouched; the caller still opens the window.
- `transcriptionItemID(for:)` now delegates to the lane-aware lookup. This
  also removes a latent cross-lane match: it previously returned any item
  that mapped the source, ingestion or extraction.

Detail view (`SourceDetailView`):

- Extract swaps to "View Extraction" while a queue extraction job runs for
  the source. The tap opens the Extraction Queue window focused on the job.
- An already-derived source (re-extraction, transcript refresh) shows the
  same "View Extraction" affordance as a standalone secondary button. The
  first-run Extract swap does not cover that case.
- The Ingest button keeps its spinner and "Ingesting…" label mid-run. The
  tap now navigates to the Agent Queue window focused on the job. A mid-run
  re-enqueue was already a no-op because the queue dedupes an active
  source, so the tap is repurposed, not lost.

Sidebar (`SourcesListView` + `SourcesContainerView`):

- Single-row context menu gains "View in Agent Queue…" when the ingestion
  spinner set contains the source, and "View in Extraction Queue…" when the
  extraction set does. Multi-row selections show neither: a running job is
  one item.
- The new `onShowRunningJob` callback keeps the AppKit side queue-free. The
  container owns the tracker and the `openActivityWindow` environment
  closure.

## Verification

- `make build` passed.
- `make test` passed (default graph). One earlier run reported a transient
  `WikiFSCoreTests` failure; a rerun with no changes passed. This branch
  does not touch `WikiFSCore`.
- `WIKIFS_APP_TESTS=1 swift test --filter QueueActivityTracker` passed:
  57 tests in 9 suites, including 6 new tests for
  `runningItemID`/`stagePendingSelectionForRunningJob`.
