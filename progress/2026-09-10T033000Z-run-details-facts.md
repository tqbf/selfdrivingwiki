---
timestamp: 2026-09-10T033000Z
title: Run Details facts panel
branch: feature/integrated-queue-workspace
status: complete
---

# Run Details facts panel

## Progress

The Run Details inspector's facts grid gained three facts and one precedence
rule. The grid is pre-mapped values (`QueueRunDetailsFacts`) rendered by
`QueueRunDetailsView`; every omit-vs-"Not Reported" decision lives in
`QueueRunDetailsFacts.entries` and is pinned by the pure value suite — the
view only renders rows.

### Job ID row

The job's queue item id (raw ULID) leads the rows as "Job ID", rendered fully
monospaced and text-selectable so the operator can copy it and correlate logs
and CLI output with the panel. The caller always maps it from
`item.id.rawValue`; only a blank string (synthetic facts) omits the row — it
is never a "Not Reported" placeholder.

### Per-field usage rows

Usage is one labeled row per PRESENT field, in this order: Input, Output,
Cached, Thought, Cost. Zero or absent fields are omitted — never a fake zero —
and a snapshot with nothing reportable produces no usage rows at all. The
single-line "In … · Out … tokens · …" form was rejected (operator request).
Token values go through `UsageFormatter.groupedCount` — locale-grouped exact
counts, never the compact "8.1K" vocabulary — so the panel reconciles against
provider usage dashboards; cost goes through `UsageFormatter.preciseCost` so
sub-cent precision survives. Only the Job ID row is fully monospaced; every
other value stays monospaced-digit.

### Provider/model mid-run fallback

The report header is only written at completion, so a running job would show
"Not Reported" next to a navigator that already shows the live model.
`ActivityWindowView.runDetailsProviderModel` (pure, `nonisolated`, suite-pinned)
resolves each side independently: a present-and-non-blank report value wins;
otherwise the usage snapshot's provider label and model name stand in — the
human-readable model name when the backend advertised one, else the raw model
id. Nothing is invented; blanks count as absent, matching `entries`.

### Retry stale-usage precedence (GLM 5.3 review fix)

The snapshot feeding both the usage rows and the provider/model fallback is
now state-aware (`ActivityWindowView.runDetailsUsage`): while
`item.state == .running` the LIVE snapshot wins (`live ?? recorded`);
otherwise the recorded one. Before this fix the panel preferred the recorded
`itemUsage` unconditionally — but `itemUsage` survives `.started` and is keyed
only by item ID, so after Retry Job the panel showed the previous attempt's
frozen totals next to a running clock. A running item with no live snapshot
yet (before the first `usage_update`) falls back to the recorded snapshot
rather than showing nothing; queued and terminal jobs keep the final recorded
totals, and a lingering live value can never override them.

Docs: `plans/integrated-queue-workspace.md` — "Run details" table extended
(Job ID row, per-field usage rows, mid-run provider/model fallback, the
state-aware snapshot rule); design change 4 amended to record that the
2026-09-09 name-only decision supersedes rendering planned rows as "Planned";
the count-only-titles entry renumbered 10 → 9 (entry 9 was missing and change
8's body already cross-referenced "design change 9").

## Verification

- `make build` green (builds + signs).
- `WIKIFS_APP_TESTS=1 swift test --filter
  'QueueWorkspacePresentationTests|QueueClosedWikiNameResolutionTests|
  QueueWorkspaceIntegrationTests'` — 94 tests in 3 suites, all pass.
- `QueueWorkspacePresentationTests` alone — 33/33, including the three new
  pins: `runDetailsRunningItemPrefersLiveUsageOverStaleRecorded` (running +
  stale recorded + fresh live → panel reflects the live snapshot; no live yet
  → recorded stands in), `runDetailsTerminalItemKeepsRecordedUsage`
  (completed/failed/cancelled/queued → recorded wins, absence stays absence),
  and `nilStatusRowDoesNotMatchPlannedQuery` (a nil-status row's haystack has
  no "Planned", so the query cannot resurrect evidence-less rows).
- Full `make test`: **4284 tests in 465 suites, all pass** (final run; 7
  standard opt-in skips — real-Keychain, ACP smoke). Two earlier full runs on
  this tree failed for unrelated causes, both resolved: the sibling uncommitted
  note `2026-09-10T031000Z-planned-inventory-rows-name-only.md` predated the
  progress template (no front matter, no `## Progress`/`## Verification`) and
  failed `DocumentationContractTests.progressEntriesFollowTemplate` — it was
  brought to template compliance here; and one run hit the suite's documented
  load flake (`runtimeLaunchUsesRetainedAbsoluteURLWithAllowlistedEnvironment`,
  fixture startup 5.3 s of the 5.0 s budget under parallel-suite load,
  ~1-in-3 clean runs per the suite's own skip note) — it passes in isolation
  and passed on the final full run.
