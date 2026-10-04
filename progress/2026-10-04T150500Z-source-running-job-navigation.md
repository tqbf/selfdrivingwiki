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

Detail view (`SourceDetailView`) — the affordance replaces an existing
control in place. It is never an added button:

- Extract swaps to "View Extraction" while a queue extraction job runs for
  the source. The tap opens the Extraction Queue window focused on the job.
- The Ingest control swaps to "View Ingestion" mid-run: checkmark.seal.fill
  icon, prominent styling, green "done" tint suppressed while running. The
  tap opens the Agent Queue focused on the job. A mid-run re-enqueue was
  already a no-op because the queue dedupes an active source, so the tap is
  repurposed, not lost. Progress stays visible on the sidebar row spinner
  and in the Activity window.
- A source with no Extract or Ingest control shows no view affordance. An
  already-derived source being re-extracted from the derivation menu has no
  Extract button, so it has no view control either.

Sidebar (`SourcesListView` + `SourcesContainerView`):

- The single-row "Ingest" context item becomes "View Ingestion Job…" while
  an ingest job runs for the clicked source. The single-row "Extract
  Markdown" item becomes "View Extraction Job…" while an extraction runs.
  The menu never gains a separate navigation item.
- The new `onShowRunningJob` callback keeps the AppKit side queue-free. The
  container owns the tracker and the `openActivityWindow` environment
  closure.

Revision after operator review: the first version added a standalone
detail-view button and two context-menu items. The final version replaces
the Ingest and Extract controls instead.

## Verification

- `make build` passed.
- `make test` passed (default graph). One earlier run reported a transient
  `WikiFSCoreTests` failure; a rerun with no changes passed. This branch
  does not touch `WikiFSCore`.
- `WIKIFS_APP_TESTS=1 swift test --filter QueueActivityTracker` passed:
  57 tests in 9 suites, including 6 new tests for
  `runningItemID`/`stagePendingSelectionForRunningJob`.
- After the revision: `make build` passed and the same tracker filter
  passed again (57 tests, 9 suites).
