---
timestamp: 2026-07-22T193227Z
title: "feat: Lint button navigates to lint job in Activity window (#837)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Lint button navigates to lint job in Activity window (#837)

## Progress


**Goal:** when a lint job is running/queued for a page, the Lint button in
PageDetailView navig to the specific lint job in the Activity window instead
of showing a static alert.

**Approach:**
- Added `lintItemID(for:wikiID:)` to `QueueActivityTracker` that resolves the
  running lint item for a given page (page-level match by page ID, whole-wiki
  match by wiki ID). Backed by two new tracking dicts (`itemToLintPageIDs`,
  `itemToLintWikiID`) populated on `.started` and cleaned up on terminal state.
- Added `pendingSelectionItemID` property to the tracker — a shared
  `@Observable` "pending selection" that `PageDetailView` sets before opening
  the Activity window. `ActivityWindowView` consumes it on appear + onChange,
  setting `selectedItemID` and clearing the pending value.
- `PageDetailView.lintButton`: when linting, the button swaps to "View Lint"
  with `checkmark.seal.fill`, stays enabled, and taps resolve the lint item ID
  → set pending selection → call `openActivityWindow?()`. Removed the old
  `.disabled` + alert behavior entirely.
- `ActivityWindowView`: added `consumePendingSelectionIfNeeded()` called from
  `.onAppear` + `.onChange(of: activityTracker.pendingSelectionItemID)`, plus
  a safety-net comment on the existing `autoSelectIfNeeded` onChange handlers.
- 9 new tests covering page-level resolution, whole-wiki resolution, cross-wiki
  scoping, unlisted-page nil, mapping cleanup on completion/cancellation, and
  pending selection default/stop behavior.

**Files touched:**
- `Sources/WikiFS/Queue/QueueActivityTracker.swift` — new tracking dicts +
  `lintItemID(for:wikiID:)` + `pendingSelectionItemID` + cleanup in
  `.started`/`removeItem`/`stop()`
- `Sources/WikiFS/Queue/ActivityWindowView.swift` —
  `consumePendingSelectionIfNeeded()` + `.onChange(of: pendingSelectionItemID)`
  + `.onAppear` call
- `Sources/WikiFS/Pages/PageDetailView.swift` — `openActivityWindow` env,
  removed alert + `.disabled`, new navigation action
- `Tests/WikiFSAppTests/QueueIngestionTests.swift` — 9 tests in
  `QueueActivityTrackerLintItemIDTests`

## Verification

Historical verification remains in the progress record above.
