---
timestamp: 2026-09-10T050353Z
title: Report-header usage, Overview truth, toggle icon parity, navigator job-ID chips
branch: feature/integrated-queue-workspace
status: complete
---

# 2026-09-10 — Report-header usage, Overview truth, toggle icon parity, navigator job-ID chips

Four operator-approved changes on `feature/integrated-queue-workspace`
(implemented uncommitted, on top of the titles/facts/chip work already in the
tree). Plan design changes 10–13.

## Progress

### Design change 10 — no result-statement line for not-reported reports

`ActivityWindowView.resultStatement(for:)` (now `nonisolated static`) renders
only `.available` (producer summary) and `.reportingUnavailable` (honest
failure); `.notReported` renders no line. The engine-side producer summaries
in `QueueIngestionReporting` stay — only the Overview rendering dropped them.
User guide no longer quotes the sentence.

### Design change 11 — durable usage in the report header (QueueStore v8)

The bug: Run Details token counts vanished after completion/reload — usage
lived only in the tracker's in-memory session snapshots.

- `QueueReportUsage` (typed, Sendable, WikiFSCore) on `QueueAttemptReport` and
  `QueueReportMutation`; `SessionUsage ⇄ QueueReportUsage` converters live in
  WikiFSEngine (WikiFSCore cannot see `SessionUsage`).
- Migration `v8_add_attempt_report_usage`: nullable `input_tokens`,
  `output_tokens`, `cached_read_tokens`, `thought_tokens` (INTEGER), `cost`
  (REAL), `currency` (TEXT) on `queue_attempt_reports`. Column-guarded
  (`db.columns(in:)` — the vendored GRDB has no `columnExists`), because
  hand-rolled-era DBs re-run the whole ladder and dev DBs may carry
  intermediate shapes.
- `commitReportMutation` writes usage via `COALESCE` (non-usage mutations
  never clobber); `resetHeaderToExecution` NULLs the columns (a new
  execution discards the dead dispatch's usage).
- `agentCompletionMutation` commits the launcher's `runTotalUsage` — the
  same values the navigator showed live (app + daemon share the builder).
  A failed or cancelled run intentionally keeps its usage on the v4
  activity-record path (the report header usage stays NULL); the
  completion mutation commits usage only for runs that pass outcome
  validation.
- Run Details precedence: terminal states read the report header first, the
  tracker's recorded snapshot is the fallback; running prefers live over the
  (possibly previous-attempt) recorded snapshot. Legacy NULL columns decode
  `usage == nil` — never zeros.

### Design change 12 — Run Details toggle icon parity

`RunDetailsToolbarToggle`/`ToolbarIconButton` removed;
`runDetailsInspectorToggle` is now a plain SwiftUI toolbar `Button` mirroring
ContentView's inspector toggle (`sidebar.right`, flipping `.help`, "Run
Details" accessibility label, same `showsRunDetailsInspector` @State).

Measured in the hosted harness: this window's bridged toolbar Button
collapses to the bare glyph (23.5×18.5), so the image carries the shared
`Toolbar.iconButtonSide` square as its frame and the bridged content measures
exactly 28×28 — parity enforced, not assumed. Palette-label loss (`item.label
== ""`) accepted + documented like the search item. Hosted tests drive the
toggle via synthesized mouse events at the content frame's center (no NSButton
exists to performClick; the system AX API returns api-disabled without a TCC
grant — both verified) and assert frame parity + open/close round trip.

### Design change 13 — navigator job-ID chips

Every navigator row (both queue windows share `ActivityWindowView`) shows the
job's own queue item id: full raw ULID, `caption2.monospaced()` secondary on
its own line, `.textSelection(.enabled)`, tooltip = the id, plus a
context-menu **Copy Job ID** action. `ActivityWindowView.jobIDChipText(for:)`
is the pinned mapping; target SourceID/PageID values stay hidden everywhere.

## Verification

- Value pins: `resultStatementRendersProducerSummariesAndHonestFailureOnly`,
  report-first usage precedence (report wins terminal, legacy falls back,
  running prefers live), chip = `item.id.rawValue` + no target-ID leak.
- Store: pre-usage DB migration reopen (table rewound to v7 shape + v8
  untracked via the raw-SQL bypass), completion commits usage, durability
  across reopen, COALESCE non-clobber, new-execution reset.
- Engine: completion mutation maps usage fields; `usage == nil` when none.
- Green: targeted filters (127), QueueReportStore (14),
  ActivityWindowWorkspaceHostedTests (15), full `make test` (4286/465).

## Risks / notes

- `ProvenanceDeletionRestrictionTests.multipleVersionsAndPagesReturnOrdered
  DistinctBlockers` is order-flaky across processes (Dictionary `.values`
  compared to a positional array) — pre-existing, unrelated to this diff;
  passes in isolation and on the rerun. Candidate for a follow-up sort fix.
- The Run Details a11y label/tooltip cannot be asserted from the hosted
  harness (no NSButton bridge, no AX without TCC) — pinned by view code, not
  by tests.
