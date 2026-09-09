---
timestamp: 2026-09-08T074500Z
title: Integrated queue workspace review follow-ups
branch: feature/integrated-queue-workspace
status: complete
---

# Integrated queue workspace review follow-ups

Branch: `feature/integrated-queue-workspace`. This entry records the follow-ups
from the final GLM review round (H1, M1–M4, L1, L2, L5). The review text lives
in the operator session (`glm-final-review`). All changes stay on the branch.
The agent made no commits.

## Progress

What changed:

- **H1 hosted scenarios.** New suite
  `Tests/WikiFSAppTests/ActivityWindowWorkspaceHostedTests.swift`. One real
  hosted `NSWindow` mounts the production `ActivityWindowView`. Twelve named
  scenarios drive it: harness label+action, failed/queued action states,
  ingest/lint/whole-wiki shared workspace, Stop All semantics, preferred and
  minimum layout sizes with accessibility names, a 300-target lazy
  inventory with last-row reachability, the Run Details inspector toggle
  end to end (literal six-row facts table, center-inventory preservation,
  and inspector-open coverage at the 640×400 minimum), non-collapsible
  name-link inventory rows, and strict queue scope (extraction jobs never
  list in the Agent Queue). The count is corrected to the current suite;
  the last three scenarios landed in the design-change round that moved Run
  Details to the inspector. The suite is serialized and
  time-limited, and it uses bounded cooperative waits only. See the suite
  header for the bridged-surface discovery model and the environment limits.
- **M1 live progress gate.** `QueueWorkspaceMapper.headerProgress` now takes
  the job lifecycle and returns `nil` unless the job is running. A failed or
  cancelled job with an open recorded phase no longer renders a live-looking
  progress bar in the header or the navigator row line.
- **M2 name index.** New `Sources/WikiFS/Queue/QueueTargetNameIndex.swift`
  replaces the per-item linear scans over `sources`/`summaries` in
  `ActivityWindowView`. One index per live wiki per render now serves those
  lookups. Regression tests pin first-match semantics and payload-order
  resolution. The observation-crash workaround is unchanged: the index is
  built inside `buildRowDisplayData`, and row bodies read plain values only.
- **M3 outside-filter notice.** Filters that hide the selected job keep the
  workspace and show "Selected job is outside this filter" with a **Clear
  Filters** action. `isHiddenByFilter` shares the navigator's search-text
  helper, so the two cannot disagree.
- **L1 reorder disable.** `.moveDisabled` applies while filters or search are
  active. The footer keeps the visible explanation.
- **L2 summary bounds parity.** `QueueWorkspaceMapper.summary(from:)` now
  folds search text with the store's exact bounds (64 target records × 3
  fields, 200-char field cap, 8000-char total). Event-synthesized and
  store-loaded summaries now find the same text.
- **L5 orphaned cancel projection.** The defensive requeue branch in
  `QueueEngine.handleWorkerFinished` now runs the same guarded interrupted
  projection that the cancel/halt paths use. An orphaned cancellation cannot
  leave live target states in the report.
- **M4 user guide.** `docs/user-guide/organizing-and-managing.md` and
  `docs/user-guide/sources-and-ingestion.md` now document Pause Queue vs
  Stop All (queued jobs stay queued), the Overview/Activity workspace, the
  loaded-jobs search scope, the outside-filter notice, the 200-item Recent
  limit, and Not Reported behavior.
- **Accessibility fix.** The navigator rows' icon-only Cancel/Retry buttons
  carry explicit accessibility labels. The Queue Actions menu uses a titled
  label.

Tests added or extended:

- `ActivityWindowWorkspaceHostedTests`: 12 tests, gated by
  `WIKIFS_APP_TESTS=1` (count corrected to the current suite).
- `QueueWorkspaceIntegrationTests`: `headerProgressRendersNothingForDeadJobsEvenWithOpenPhase`,
  `progressLineGatesDeadJobsAtTheRowSeam`,
  `summarySynthesisMatchesStoreFieldBounds`,
  `nameIndexMatchesLinearScanSemantics`,
  `displayNamesPreservePayloadOrderAndWholeWikiMarker`.
- `QueueReportEngineTests`: `orphanedCancelRequeueProjectsInterruptedReport`,
  plus `OrphanedCancelWorker` fakes.

## Verification

- `make build`: passed (signed app bundle).
- `make test`: passed. 4276 tests, 464 suites.
- `WIKIFS_APP_TESTS=1 swift test --filter ActivityWindowWorkspaceHostedTests`:
  12/12 passed (count corrected to the current suite; the original entry
  recorded 9/9 before the inspector, name-link, and queue-scope scenarios
  landed).
- `swift test --filter QueueReportEngineTests`: 17/17 passed. This count
  includes the new orphaned-cancel test.
- `QueueWorkspaceIntegrationTests` passed inside the gated lane. The run
  included the new M1/M2/L2 tests.
- Full gated lane (`--filter WikiFSAppTests`): 36 failures. All failing
  suites also fail in the previous session's baseline logs (EnvVarHints,
  networked renderer/daemon suites). Hosted suites that start without
  completing show the same pattern as the pre-existing
  `ActivityWindowTypedTranscriptTests` in those baseline logs. These are
  pre-existing environment limits. This round did not cause them.
- Manual `QueueWorkspaceVisualReview`: NOT run. The plan's screenshot section
  stays "None yet".

## Known limits (hosted harness)

SwiftUI draws `Text` and custom-labeled buttons into its own layer. In the
`swift test` host those layers never reach the AppKit view tree or the
in-process accessibility tree. Forcing manual accessibility does not change
that. The harness therefore asserts through the surfaces that DO bridge:
toolbar item labels, the segmented Overview/Activity selector, popup button
titles, editable-field placeholders, real row-cell `NSButton`s, and the
inventory's `NSTableView`. Label text pinned by the value-level suites stays
there. A second full Activity-window mount in one process exits silently, so
the suite shares ONE mounted window for all scenarios.
