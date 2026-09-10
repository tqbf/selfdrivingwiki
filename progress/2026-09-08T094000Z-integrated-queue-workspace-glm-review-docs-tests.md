---
timestamp: 2026-09-08T094000Z
title: Integrated queue workspace GLM 5.3 review follow-ups (docs and test integrity)
branch: feature/integrated-queue-workspace
status: complete
---

# Integrated queue workspace GLM 5.3 review follow-ups (docs and test integrity)

Branch: `feature/integrated-queue-workspace`. This round answers the GLM 5.3
review follow-ups. Production behavior was already implemented in the working
tree; this round corrects documentation and test integrity only. The approved
design is preserved: optional right Run Details inspector, Queue Actions menu
with Pause/Resume and Stop All plus explanatory text, non-collapsible
source/page name links with no IDs, operation-prefixed titles, strict queue
separation, and disabled queue-window restoration. No commits. No pushes.

## Progress

Documentation:

- `docs/user-guide/organizing-and-managing.md` — the job workspace section now
  describes current behavior: operation-prefixed header titles, non-collapsible
  Overview rows whose name is the link (Open Page / Reveal Source / Browse
  Pages), no IDs, tooltips for full recorded names, and the Run Details
  inspector as a toolbar-toggled optional panel that shows times, duration,
  attempt, provider, model, and usage with Not Reported for absent values.
- `docs/user-guide/sources-and-ingestion.md` — the activity windows section now
  describes the one Queue Actions menu (Pause/Resume plus Stop All) with its
  guidance text, the Run Details toggle, and an Overview that shows targets
  only.
- `plans/integrated-queue-workspace.md` — new dated section "Design changes
  (2026-09-08)" records the three superseding decisions (inspector, Queue
  Actions menu, non-collapsible name links). The affected sections ("Selected
  job workspace", "Target inventory", "Run details", "Pause and Stop All",
  "Non-goals") were amended in place, and the status line no longer claims
  tests have not run.

Stale comments corrected (no behavior change):

- `Sources/WikiFS/Queue/ActivityWindowView.swift` — removed "expandable agent
  transcripts" and the disclosure-era references; the detail-pane doc now
  describes the Overview/Activity selector and the inspector.
- `Sources/WikiFS/Queue/QueueTargetRow.swift` — the comment named the source
  action "Open Source"; the code labels it "Reveal Source". Fixed the comment.
- `Sources/WikiFS/Queue/QueueWorkspacePresentation.swift` — four "Run Details
  disclosure" references now say inspector panel; two row-identity comments no
  longer mention disclosure state.
- `Sources/WikiFS/Queue/QueueActivityTracker.swift` — the pendingPermission
  handler said "the array"; `pendingPermissions` is a dictionary keyed by item
  ID.

Test integrity:

- Outside-filter notice value coverage. The notice previously used inline
  strings while unused constants existed in the extension — a drift risk. The
  notice now renders `filteredSelectionNoticeText` and
  `clearFiltersButtonLabel`, and the decision seam is testable:
  `ActivityWindowView.isHiddenByFilter(_:filter:rowTitle:wikiName:targetNames:summarySearchText:)`
  and `navigatorSearchText(...)` are pure `nonisolated` statics (the instance
  methods delegate; `kindLabel(for:)` became a static pure helper). New test
  `outsideFilterNoticeSharesNavigatorMatchAndPinsCopy` in
  `QueueWorkspaceIntegrationTests` pins the show condition (no filter, matching
  search, target-name search, rejected search, summary search, state filter,
  operation filter, whitespace-only search) and the exact copy.
- Hosted inspector test strengthened in `ActivityWindowWorkspaceHostedTests`.
  The facts-table row count is now the literal `6` (three timestamps, duration,
  two Not Reported placeholders; attempt 0 omitted; no usage) instead of a
  count recomputed from `QueueRunDetailsFacts.entries`, which could pass even
  if `entries` dropped a row. The minimum-size pass now re-opens the inspector
  before resizing, so 640×400 is covered with the inspector open: the facts
  table stays mounted, the inventory keeps its rows and height floor, and the
  workspace stays inside the window. The inspector is closed after the pass so
  later scenarios start clean.
- `progress/2026-09-08T074500Z-integrated-queue-workspace-review-followups.md`
  — hosted test count corrected from 9 to the current 12, with the three
  newer scenarios named.

## Verification

- `make build`: passed (signed app bundle).
- `WIKIFS_APP_TESTS=1 swift test --filter QueueWorkspaceIntegrationTests`:
  33/33 passed (includes the new outside-filter test).
- `WIKIFS_APP_TESTS=1 swift test --filter ActivityWindowWorkspaceHostedTests`:
  12/12 passed.
- Documentation contract suites (ungated):
  `SourceTypeDocumentationConsistencyTests` +
  `RendererPackageDocumentationTests` + `CordisDocumentationContractTests`:
  9/9 passed across the 3 suites.
- `WIKIFS_APP_TESTS=1 swift test --filter
  "QueueWorkspacePresentationTests|QueueJobFilterTests"`: 19/19 passed.

## Known limits

- The layout art in `plans/integrated-queue-workspace.md` still shows the old
  "Run Details ▸" footer row; the dated design-change section states the
  inspector replaces it.
- The hosted suite cannot see SwiftUI-drawn label text, so the notice's copy
  is pinned at value level only (documented in both the test and the suite
  header).
- One hosted assertion was attempted and removed: "exactly one six-row facts
  table" — AppKit retains retired List tables, so table-count uniqueness is
  not a reliable signal (the suite header documents this hazard).
