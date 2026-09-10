---
timestamp: 2026-09-10T031000Z
title: Planned inventory rows render name-only
branch: feature/integrated-queue-workspace
status: complete
---

# Planned inventory rows render name-only (2026-09-10)

Branch `feature/integrated-queue-workspace`, uncommitted on top of the
count-only-titles + Run Details facts work. Operator decision (2026-09-09):
in the queue Overview inventory, "Planned" is the default state, so labeling
an evidence-less row with it communicates nothing. Those rows now render
name-only — no status circle, no "Planned" text.

## Progress

### Mechanism

Typed signal, not string comparison: `QueueTargetRowValue.status` became
`QueueWorkspaceStatus?`. `nil` means "no recorded evidence" and the row
renders name-only. A present status keeps the chip (symbol + text).

- `QueueWorkspaceMapper.targetStatus(for:result:)` now returns
  `QueueWorkspaceStatus?` and maps `.planned` and `.notReported` to `nil`.
  Real recorded states (Preparing, Submitted, Processing, Succeeded,
  Skipped, Failed, Interrupted) still map to their chip vocabulary.
- `QueueTargetRow.statusColumn` is a `@ViewBuilder` that renders the
  `Label` only when a status is present — no empty status element reaches
  the accessibility tree, and the row stays a labeled name link.
- `ActivityWindowView.legacyOverview` passes `status: nil` for its two
  payload-derived planned-row sites (those rows never ran, so they carry no
  evidence by definition).
- Unchanged on purpose: the whole-wiki scope row keeps its live lifecycle
  status; the Outputs section keeps its "Recorded" chip;
  `QueueWorkspaceStatus.planned()` stays in the status vocabulary (the
  closed-wiki name precedence and the F1 action gate are untouched).
- `matches(query:)` folds `status?.text`, so a planned row simply has one
  less search haystack; other rows still match on status text.

### Tests

- `QueueWorkspacePresentationTests`: new
  `plannedRowsCarryNoStatusRealStatesKeepChip` pins the mapper nil-mapping
  and chip retention; `targetStatusVocabulary` comment updated; fixtures
  that modeled planned rows now pass `status: nil`.
- `QueueWorkspaceIntegrationTests`:
  `targetStatusNeverProjectsInterruptedAsFailedOrSucceeded` now asserts
  `.planned`/`.notReported` → `nil` (supersedes the 2026-09-08
  "render as Planned" presentation) and reads the optional returns.
- `QueueOverviewLayoutHostedTests`: planned fixtures → `status: nil`.

## Verification

Evidence: `make build` green; `WIKIFS_APP_TESTS=1 swift test --filter
'QueueWorkspacePresentationTests|QueueClosedWikiNameResolutionTests|
QueueWorkspaceIntegrationTests'` — 91 tests, all pass.
`ActivityWindowWorkspaceHostedTests` — 15 tests pass (2 pre-existing
sandbox-gated skips). Each of the four `QueueOverviewLayoutHostedTests`
tests passes individually.

Known environment issue (pre-existing, not from this change): a
suite-level run of `QueueOverviewLayoutHostedTests` in this agent sandbox
stops after its second test with an `EXC_GUARD` (guarded-fd CLOSE) crash
of `swiftpm-testing-helper` and a truncated-but-zero exit. Reproduced
identical truncation with all work stashed at HEAD (5a39812e), so it is
environmental; run the suite's tests individually here until it is
diagnosed.
