# Integrated Queue Workspace

Status: **design approved and implemented** on
`feature/integrated-queue-workspace`. The design changes below supersede
the affected sentences in the sections that follow.

This document records the approved design for the redesigned Agent Queue and
Extraction Queue windows. It covers the layout contract, the state vocabulary,
the report truth rules, the queue controls (Pause versus Stop All), whole-job
retry, and the history and search scope. The approved implementation plan lives
in the operator session copy at
`/Users/wsargent/.local/share/polytoken/sessions/0ahsf1-stunt/plan-001.md`.

Covers issues #1219, #1220, and #1221.

## Design changes

The review rounds and later operator decisions changed the presentation
decisions below. The sections below
keep their original structure. Where a sentence contradicts this section,
this section is current.

1. **Run Details is an optional right inspector.** Run Details is no longer
   a disclosure below the inventory. The window toolbar's labeled
   "Run Details" toggle opens it as a trailing panel inside the detail
   column. The panel is never a permanently visible third column, and
   toggling it touches no selection, filter, or queue state. The layout art
   above still shows the old "Run Details ▸" footer row; the inspector
   replaces it. Affected sections: "Selected job workspace", "Run details",
   "Non-goals".
2. **Queue Actions menu.** Pause Queue, Resume Queue, and Stop All… live in
   one labeled "Queue Actions" toolbar menu. Pause Queue is not a separate
   top-level toolbar button. Each menu section carries visible guidance:
   Pause stops new starts and lets running jobs finish; Stop All pauses the
   queue and cancels its running jobs, and queued jobs remain. The Stop All
   confirmation restates this. Affected section: "Queue controls: Pause and
   Stop All".
3. **Target rows are non-collapsible name links without IDs.** A row shows
   the target name and one state or result. Rows do not disclose or expand,
   and rows never render typed identity (a SourceID or a PageID). The name
   itself is the link that performs the row's live action — "Open Page",
   "Open Source", or "Browse Pages" for a whole-wiki scope. The full
   recorded name stays available as the row tooltip and in the local
   inventory search. Affected section: "Target inventory (Overview)".
4. **Unobserved targets render as "Planned" (2026-09-08; rendering superseded
   2026-09-09).** Target rows no longer show a "Not Reported" status. This
   change originally rendered a row without recorded evidence as "Planned",
   the same vocabulary as a not-yet-run job. The later operator decision of
   2026-09-09 supersedes that rendering: because "Planned" is the default
   state, labeling an evidence-less row with it communicates nothing, so
   those rows now render NAME-ONLY — no status circle, no "Planned" text
   (the typed signal is `QueueTargetRowValue.status == nil`; see the
   2026-09-10 progress note "Planned inventory rows render name-only").
   "Planned" stays in the target-state vocabulary below; it is just never
   the rendered chip for an evidence-less row. The superseded change's
   other rules stand: Planned is not a result and never reads as a zero or
   an empty success, and absence stays explicit where it matters — the Run
   Details inspector keeps its "Not Reported" placeholders for provider and
   model, and the section result line keeps sentences such as "Agent run
   completed; page-level results not reported". Affected sections: "Target
   inventory (Overview)", "Report truth rules".
5. **Overview shows Inputs and Outputs (2026-09-09).** An ingestion job's
   Overview renders two sections: "Inputs" (the payload sources — the
   former single inventory) and "Outputs" (pages whose recorded
   `page_version_sources` citations reference the input sources). Outputs
   resolve only from recorded store evidence through the read-only
   `pagesCitingSources` accessor; they are never inferred from job
   completion. Output rows are clickable page names (Open Page) that stay
   resolvable through the live store, degrade recorded names for deleted
   pages, and never render a fake zero: loading, empty, and failed states
   each have their own truthful text. Lint and extraction keep their
   existing single section. Affected sections: "Target inventory
   (Overview)", "Report truth rules".
6. **Toolbar search sits left of Queue Actions and collapses narrow
   (2026-09-09, superseded by design change 18).** The job search is an explicit toolbar control instead of
   the SwiftUI `.searchable` field, declared so it renders LEFT of the
   Queue Actions menu. At split-view widths of 800 points or more it hosts
   an expanded native `NSSearchField` (in-field magnifying glass, clear
   button, Escape-to-clear); narrower windows collapse it to a
   magnifying-glass button that expands and focuses the field on click, and
   the control collapses again when the query empties or editing ends with
   the field empty while the window is narrow — `NSSearchToolbarItem`
   behavior. Focus is taken only by the click that requested expansion,
   never by a resize across the threshold. The query binding, its scope
   (loaded jobs only), the "Search loaded jobs" prompt and accessibility
   label, and the outside-filter and reorder-guard semantics are unchanged.
   Affected sections: "Layout contract", "Selection, filters, and deep
   links".
7. **Icon-only toolbar controls pin right (2026-09-09).** The window toolbar
   borrows the main window's geometry (ContentView): the search control
   leads, a `ToolbarSpacer(.flexible)` eats the middle, and an icon-only
   control group pins to the trailing edge — the Queue Actions menu and the
   Run Details inspector toggle always show on the right. Both controls
   render icon-only (ellipsis-circle and sidebar.right, borderless). The
   visible titles are gone but the identities stay: each control keeps its
   accessibility label ("Queue Actions" / "Run Details"), the menu button
   shows a "Queue Actions" tooltip, the toggle's tooltip states
   "Show Run Details" / "Hide Run Details", and the toggle's toolbar item
   label ("Run Details") remains for the customization palette. The icons
   keep the group compact enough to stay out of the overflow at the 640×400
   minimum; this window keeps its navigationTitle/subtitle (they identify
   Agent Queue vs Extraction Queue), so unlike the main window it cannot
   also reclaim the title slot — small controls are the whole budget.
   The layout art still shows the old labeled "Pause Queue" and
   "Search Jobs" toolbar row; the icon-only group replaces it.
   Affected sections: "Layout contract", "Queue controls: Pause and Stop
   All".
8. **Closed-wiki jobs keep names and click-through (2026-09-09).** A job
   whose wiki window is closed keeps readable target rows and its
   navigation. Three layers answer "what is this target called", in
   precedence order: the open wiki's live session index; the payload's
   enqueue-time recorded names (`QueueItemPayload.recordedNames`,
   captured at the lint and ingestion enqueue sites); and a read-only
   name load against the closed wiki's database
   (`QueueClosedWikiNameLoader` through `WikiReadService`, bounded to the
   payload's IDs), cached per wiki in `QueueActivityTracker`. While that
   read is pending, unresolved rows show the neutral "Resolving…"
   placeholder, never the deletion text. A known target on a closed wiki
   keeps its click-through: the click stashes a `wiki://` deep link and
   opens the wiki window, and the navigation lands once the session
   exists (`QueueTargetRouter`). The action gate is open/closed aware: on
   an OPEN wiki, an action additionally requires LIVE store membership —
   a target deleted after enqueue keeps its recorded title but gets no
   dead-end action; on a CLOSED wiki the click-through stays, because the
   stash+open route resolves at click time. Target names still come from
   the effective index in both cases. They feed inventory rows, job titles,
   navigator tooltips, and search. Design change 17 supersedes the count-only
   title rule. The load refresh keys on the displayed
   jobs' target composition AND the open-wiki set (a window closing
   re-triggers it); items arriving mid-load are parked on the in-flight
   wiki and re-planned once after the load; IDs a completed load proved
   missing are negative-cached so they never reopen the read-only
   database; and a cancelled load is retryable, never an "unavailable"
   wiki. Affected sections: "Target inventory (Overview)", "History and
   search scope".
9. **Count-only titles (2026-09-09, superseded by design change 17).** Target names left
    the job header title and the navigator row titles entirely: both now
    carry the operation and the target count only — "Ingest 12 sources" /
    "1 source", "Lint 3 pages", whole-wiki "Lint <wiki>" — because a closed
    wiki could surface a raw target ID where a name was expected. The
    header title prefixes the operation word over the count: "Ingestion:
    12 sources", "Extraction: 1 source", "Lint: 3 pages", whole-wiki
    "Lint: <wiki>". No raw ID can reach a rendered title. Names stay
    everywhere else: the Overview inventory rows keep their names and
    click-through (design change 8), navigator rows keep the names tooltip,
    and search still matches target names. Affected sections: "Job
    navigator (left)", "Selected job workspace (right)".
10. **No result-statement line for not-reported reports (2026-09-10,
    operator request).** The Overview's result statement resolves only for
    `.available` reports (the producer's recorded summary) and
    `.reportingUnavailable` (the honest failure). A `.notReported` report
    renders NO statement line: the producer sentences ("Agent run
    completed; per-source ingestion outcomes are not reported", and the
    lint variant) only restate what the inventory rows already show state
    by state, so the line communicated nothing and read as a result. This
    supersedes design change 4's sentence keeping those sentences in the
    section result line; the engine-side producer summaries in
    `QueueIngestionReporting` stay — they remain durable report data. Only
    the Overview rendering changes. Affected section: "Target inventory
    (Overview)".
11. **Durable usage in the report header (2026-09-10, operator request).**
    The agent-completion mutation commits the launcher's accumulated
    run-total usage — the same values the navigator shows live — into the
    report header (`queue_attempt_reports` gains nullable `input_tokens`,
    `output_tokens`, `cached_read_tokens`, `thought_tokens`, `cost`, and
    `currency` columns; additive migration v8). Run Details reads the
    report header's usage FIRST; the tracker's recorded-or-live snapshot
    stays the mid-run fallback (a running item still prefers live), so
    token counts no longer vanish from Run Details after completion or
    reload. Legacy reports with NULL usage columns render no usage rows —
    never fake zeros. A failed or cancelled run intentionally keeps its
    usage on the v4 activity-record path (the report header usage stays
    NULL); the completion mutation commits usage only for runs that pass
    outcome validation. Affected section: "Run details".
12. **Run Details toggle icon parity (2026-09-10, operator request).** The
    toolbar toggle is a plain SwiftUI toolbar `Button` mirroring the main
    window's inspector toggle exactly: the `sidebar.right` system image,
    a `.help` tooltip that flips with state, no visible title, and the
    "Run Details" accessibility label. This replaces the
    `RunDetailsToolbarToggle` NSViewRepresentable; the palette-label loss
    (no SwiftUI title to lift into the `NSToolbarItem` label) is accepted
    and documented like the search item. Affected section: "Selected job
    workspace".
13. **Navigator job-ID chips (2026-09-10, operator request).** Every
    navigator row shows the job's OWN queue item id as a small chip: the
    full raw ULID in caption2 monospaced secondary on its own line below
    the subtitle, text-selectable where supported, with a "Copy Job ID"
    context-menu action that writes the ULID to the pasteboard. The chip is
    the QUEUE ITEM id only — target SourceID/PageID values stay hidden
    everywhere. Rows use target-name titles and never expose target IDs, per
    design changes 3 and 17. Both queue windows share the navigator, so
    the chip appears in both. Affected section: "Job navigator (left)".
14. **Durable ingestion output snapshots (2026-09-10).** The report owns a
    bounded snapshot of output `PageID` values and completion-time titles.
    Migration v9 stores these rows and an `outputs_recorded` presence bit.
    The Overview reads this snapshot without an open wiki. A live wiki can
    improve a title and supply an Open Page action, but it cannot change output
    identity. This supersedes design change 5's live-query rule. Affected
    sections: "Target inventory (Overview)", "Report truth rules".
15. **Shared titles and operation chips (2026-09-10).** The navigator and
    selected-job header use one title value. A neutral operation chip identifies
    ingestion, extraction, or lint without changing that title. This supersedes
    design change 9's operation-prefixed header and design change 13's separate
    job-ID line. Affected sections: "Job navigator (left)", "Selected job
    workspace (right)".
16. **Job and wiki identity metadata (2026-09-10).** Navigator metadata shows
    the queue item ID with state, progress, or elapsed time. Its tooltip and
    context menu expose the full ID. The selected-job header shows the wiki name
    before the selectable full job ID, lifecycle state, and elapsed time.
    Target IDs remain hidden. Affected sections: "Job navigator (left)",
    "Selected job workspace (right)", "Run details".
17. **Target-name job titles (2026-09-10, operator request).** A job title uses
    the first payload target name. A batch adds "and 1 other" or "and N others."
    A whole-wiki job uses the wiki name. Payload order determines the first
    target. If its name is unavailable, the title uses count wording instead of
    a later target or raw ID. This supersedes design change 9. Affected sections:
    "Job navigator (left)", "Selected job workspace (right)".
18. **Search moves into the navigator (2026-09-10, operator request).** The job
    search is an always-visible field at the top of the left sidebar, above the
    filter row and job sections. It no longer appears in the window toolbar and
    does not collapse at narrow widths. Its query, loaded-job scope, report-load
    footer, outside-filter notice, and reorder guard stay unchanged. This
    supersedes design change 6. Affected sections: "Layout contract", "Job
    navigator (left)", "Selection, filters, and deep links".

## Goal

Both queue windows show planned work, current state, recorded outcomes, and
recovery actions without reading logs. The old presentation led with the
transcript. The new presentation leads with a summary. A searchable job
navigator sits on the left. The selected job's workspace sits on the right.
Ingestion, extraction, and lint share one set of components and differ only in
their scope and result language.

The design keeps the two existing queue windows, their window identities, and
their scheduling semantics. It adds no third column and no new UI dependency.

## Layout contract

This is a layout contract, not pixel-perfect artwork.

```text
┌───────────────────────────────────────────────────────────────────────────┐
│ Native title bar   Agent Queue                 Queue Actions   Details   │
│                    1 running · 4 queued                                  │
├─────────────────────────┬─────────────────────────────────────────────────┤
│ Search loaded jobs      │ Research papers and 11 others [Ingest] Cancel │
│ All Jobs  [Filter ▾]    │ Research Wiki · 01M… · Running · 2m 14s        │
│ ACTIVE                  │ Staging sources: 8 of 12                       │
│ ◉ Research papers…      │ ━━━━━━━━━━━━━────────                          │
│   [Ingest] 01M… · 2m    │ [Overview | Activity]                          │
│                         ├─────────────────────────────────────────────────┤
│ ◷ Check selected…       │ Sources (12)                Find in Sources    │
│   [Lint] 01M… · Queued  │ Name                         State / Result     │
│   Queued                │ Long source title…           Submitted         │
│                         │ Another source               Skipped           │
│ RECENT                  │   Source bytes unavailable                      │
│ ⚠ Research papers       │ … independently scrollable inventory …         │
│   [Ingest] 01M… · Failed ├────────────────────────────────────────────────┤
│                         │ Run Details ▸   Actual provider when reported  │
└─────────────────────────┴─────────────────────────────────────────────────┘
```

The workspace is primary content, not a narrow inspector. Native toolbar and
sidebar materials supply the structure. The design avoids dashboard cards,
repeated badges, custom traffic lights, and permanently visible raw metadata.

### Job navigator (left)

- The navigator keeps the Active and Recent sections and the current engine
  order.
- Each row uses the first payload target name as its title. A batch adds
  "and 1 other" or "and N others." A whole-wiki job uses the wiki name.
  An operation chip identifies ingestion, extraction, or lint. The metadata
  shows the job ID and one state, progress, or elapsed value. An unresolved
  first name uses count wording. No row title shows a raw target ID.
- The job search stays visible at the top of the navigator, above the filter
  row and job sections. It uses the full sidebar width at all window sizes. The
  one filter menu covers State, Wiki, and Operation.
  Operation appears in Agent Queue only. Defaults are All. Active filters
  show with a clear action.
- Width: minimum 220, ideal 280, maximum 360 points. These values live in
  `QueueWorkspaceMetrics`.

### Selected job workspace (right)

The header uses the same target-name title as the navigator and shows the same
operation chip. Its metadata shows the wiki name, job ID, lifecycle state, and
one elapsed clock. The current recorded phase appears below that metadata. The
header carries Cancel for queued or running jobs. It carries Retry Job for
failed or cancelled jobs.

The workspace stacks in this order:

1. Job errors and pending permission requests.
2. The Overview and Activity selector.
3. Overview: the complete target inventory.
4. Activity: the typed transcript or the raw progress fallback, Copy Activity,
   and the existing log and debug reveal controls.

Run Details is not part of this stack. The window toolbar's "Run Details"
toggle opens it as an optional trailing inspector beside the workspace (see
the design changes above and the "Run details" section).

Every new selection opens Overview. Switching between Overview and Activity
must not drop streaming data or scroll position. Activity is the only
transcript surface.

### Target inventory (Overview)

- A native scrolling List shows every payload source or selected page before
  execution starts.
- One shared row component serves ingestion, extraction, and lint.
- The Name and State / Result columns align when space permits and stack when
  the window is narrow.
- Long names wrap to two lines. Rows do not disclose or expand, and rows
  never render typed identity (a SourceID or a PageID). The name itself is
  the link that performs the row's live action — "Open Page", "Open Source",
  or "Browse Pages" for a whole-wiki scope. The full recorded name
  stays available as the row tooltip and in the local search.
- A local search field covers large batches. Rows are lazy and keyed by
  `SourceID` or `PageID`.
- A confirmed deleted target reads differently from an unavailable wiki
  session. History rows keep their recorded names.
- Source rows use Open Source navigation for the selected source. Page rows
  use Open Page. Extraction output actions appear only when
  a recorded output reference stays resolvable.

### Run details

Run Details is an optional trailing inspector panel inside the detail
column, opened and closed by the window toolbar's labeled "Run Details"
toggle. It is never a permanently visible third column, and toggling it
touches no selection, filter, or queue state. It uses labeled values:

| Value | Note |
| --- | --- |
| Job ID | The job's queue item id (raw ULID) — the panel's FIRST row, rendered monospaced and text-selectable so the operator can copy it and correlate logs and CLI output with the panel. The caller always maps it from the item id; only synthetic facts without one omit the row |
| Enqueue, start, and finish time | One label per time |
| Duration | One elapsed clock in the header, history here |
| Attempt | The current attempt number |
| Actual provider and model | Shown only when reported. While a run is in flight the report header is still unwritten, so the recorded-or-live usage snapshot stands in: its provider label and model name (the human-readable name when the backend advertised one, else the raw model id) — the live session's own labels, never invented. Report header values win again once completion writes them |
| Usage and cost | One labeled row per present field, in this order: Input, Output, Cached, Thought, Cost. Zero or absent fields are omitted — never a fake zero — and a snapshot with nothing reportable produces no usage rows. Token values are locale-grouped exact counts (never the compact "8.1K" vocabulary) so the panel reconciles against provider usage dashboards; cost keeps sub-cent precision |

The view omits unavailable optional values. Where absence matters, it shows
Not Reported. The capacity bucket `default-ingest` never appears as the actual
provider.

The usage snapshot is state-aware recorded-or-live: queued and terminal jobs
show the final recorded totals from the completion `.usage` event. A running
job prefers the live session's snapshot — after Retry Job the item keeps its
id while the previous attempt's recorded totals survive the restart, and
showing them next to a running clock would misrepresent the run; before the
first live update arrives, the recorded snapshot stands in rather than the
panel showing nothing.

### Window behavior

- Preferred new-window size is near 1040×720. Restored frames win.
- The current 640×400 minimum stays usable.
- At narrow widths, header actions wrap beneath the title and target rows
  stack. The sidebar stays collapsible. No automatic third column appears.
- The inventory and the transcript each own their scroll region. The header
  and expanded metadata stay bounded so large text cannot remove all content
  space.

## State vocabulary

One name for one idea across both windows.

### Job lifecycle

`QueueItemState` stays the authority: `queued`, `running`, `completed`,
`failed`, `cancelled`. The queue-level dispatch state `QueueRunState`
(`running`, `paused`) stays separate. A queued item that waits on a permission
shows a conspicuous permission-pending presentation. Operation outcomes are
stored separately from lifecycle and never rewrite it.

### Target states

Each target in a report carries one state from this set:

| State | Meaning |
| --- | --- |
| Planned | Known before execution |
| Preparing | Work on the target started |
| Submitted | Handed to the underlying operation |
| Processing | The operation is working on it |
| Succeeded | The boundary for this operation reported success |
| Skipped(reason) | Not processed, with a recorded reason |
| Failed(reason) | The boundary for this operation reported failure |
| Not reported | No evidence reached the report |

A typed extraction result can additionally distinguish an output reference, no
content, or unavailable output. Unknown counts never present as zero.

### Operation language

| Operation | Unit | Counted language | Result language |
| --- | --- | --- | --- |
| Ingestion | Sources | Preparation and submission counts. "8 of 12 submitted", never "8 of 12 ingested" | Skipped input reasons and a run result |
| Extraction | Sources | Current phase, operation or backend when resolved | Recorded output, no content, skipped, or failure. Persisted output is distinct from a successful worker return |
| Lint | Scope or Pages | Current agent phase. Whole-wiki lint says "Whole wiki" before and during execution, never "All pages linted" | Reported page checks, findings, and changes only when the runner supplies them. Otherwise "Agent run completed; page-level results not reported" |

"No page-level results reported" is not an empty successful result.

## Report truth rules

These rules bound what the workspace may claim.

1. A recorded fact exists only when a real boundary reports it: a staging
   guard, the staged source collection, the provider launch, the usage
   report, or the persistence boundary.
2. Per-source ingestion completion is never inferred from agent exit or merge
   success.
3. Agent completion never invents target results. Current agent lint supplies
   no checked-page counts or findings, so those stay Not Reported. The design
   adds no extra linter pass, no parsing of agent prose, no counting of reads
   as checks, and no before-and-after store comparison.
4. An unattributed agent failure stays a job-level failure. One aggregate
   error never marks every target failed.
5. Unknown counts never present as zero. Determinate progress appears only
   for a known total with an observed phase-specific numerator. Otherwise the
   view shows an indeterminate indicator with a meaningful phase.
6. The actual provider and model appear only when reported. The capacity
   bucket `default-ingest` is metadata, not a provider answer.
7. Extraction records an output result only after the persistence boundary
   returns sufficient evidence, such as a created version reference. Empty
   conversion text does not count as useful content by itself.
8. A report persistence failure publishes an explicit reporting-unavailable
   state. Uncommitted outcomes never present as durable. The failure does not
   change the job's own lifecycle outcome.
9. Jobs recorded before this design have no reports. They show truthful
   unavailable states. Old report-free history is not reconstructed from logs.
10. Cancellation keeps observed outcomes. Unfinished targets project as
    interrupted or Not Reported, never as failed or succeeded.
11. A new execution identity (new lease activation, same-attempt restart, or
    halt-resume dispatch) resets the current report. Revisions increase
    monotonically. Delayed updates and loads from an older execution are
    rejected. Crash recovery never resurrects a prior running target as live
    work.

## Queue controls: Pause and Stop All

### Pause Queue

Pause Queue lives inside the labeled "Queue Actions" toolbar menu; it is not
a separate top-level button. Pausing stops new starts. Running work
finishes. Resume allows dispatch again. The menu carries this guidance as
visible text.

### Stop All

Stop All lives in the same "Queue Actions" menu. Its confirmation states that
Stop All pauses this queue and cancels its running work. It does not delete queued
work, and the confirmation does not imply that it does.

## Whole-job retry

Retry Job appears for failed or cancelled jobs in the selected-job header and
the row context menu. Retry keeps the existing whole-job semantics: the whole
job runs again as a new attempt.

- The new attempt starts with a fresh report and does not inherit the old
  attempt's target successes.
- Previous attempts stay stored. This design adds no attempt-history browser.
- Retry preserves the existing retry scope. The design changes no scheduling
  behavior.

## History and search scope

### What history exists

The Recent section shows the existing 200-item recent display limit. It is
recent history, not all history. Jobs that history pruning has removed do not
appear. Every label describes the scope truthfully.

### What search covers

Search is window-scoped. It matches job kind, wiki name, full resolved target
names, and recorded outcome text. Search sees only loaded history, and the
label says so. Search results never depend on which jobs the user previously
selected.

### How summaries load

Row progress and outcome search use batched job summaries, not full reports.
Each summary carries the attempt and revision, phase counts, result text, and
recorded target search text. Summaries do not carry findings or full
diagnostics. Full target detail stays on the selected item.

- Summaries load asynchronously after attach. Lifecycle-only rows appear
  immediately.
- While loading, result search is labeled incomplete.
- If loading fails, lifecycle-only rows stay, report-backed search is labeled
  unavailable, and the failure is logged. No error banner appears. Loading
  retries on reconnect or explicit refresh.

### Selection, filters, and deep links

- Selection survives lifecycle transitions. A finishing job or an arriving job
  does not steal selection.
- A deep link clears conflicting filters, selects the requested job, and shows
  Overview. The queue ownership guard stays.
- If filters hide the selected job, its workspace stays with a short notice
  ("Selected job is outside this filter") and a Clear Filters action.
- If the selected item leaves loaded history, the workspace shows an explicit
  unavailable state, never another job's content.
- Queued-job reordering stays. It is disabled when filters or search hide
  queue neighbors, with a visible explanation. Reordering never uses a
  filtered index.

## Reporting transport summary

Reports persist in additive QueueStore migrations. Each attempt has one
header and per-target rows keyed by item, attempt, target namespace, and ID.
Ingestion attempts also store a bounded page-output snapshot after the run.
The snapshot stores typed page IDs, recorded titles, and stable row order.
A header flag distinguishes an unrecorded legacy snapshot from a recorded empty
snapshot. A new execution of the same attempt resets the snapshot.

The app and daemon query page provenance after successful agent validation.
The app performs this query after its workspace merge callback returns. A
snapshot read failure does not change a successful job result. The report keeps
the snapshot absent, and the Overview says that outputs were not recorded.
The Overview reads this snapshot from the job report and does not need an open
wiki session.

Target updates upsert only affected rows. Loads read one consistent report and
revision in a single store operation. Report updates flow through the existing
output scope and channel. The channel validates the attempt and lease, commits
before publishing, and sends `.reportUpdated` events across local, daemon, and
XPC transports. Clients load reports through `loadQueueReport(for:)` and
`loadQueueReportSummaries(for:)`.

## Non-goals

- No change to scheduling, extraction routing, agent prompts, retry scope, or
  lint algorithms.
- `AgentQueueView.swift` is a separate live chat transcript component. This
  design does not touch it.
- No new attempt-history browser.
- No permanently visible third column and no new UI dependency. The Run
  Details inspector is conditional, toolbar-toggled presentation, not a
  fixed split-view column.
- Full semantic agent-result protocols stay out of scope. Lint page findings
  and per-source ingestion completion remain Not Reported until an
  authoritative producer exists.

## Screenshots

None yet. The named manual review `QueueWorkspaceVisualReview` adds screenshots
to this section during implementation verification. This document does not
claim that review has run.

## Related

- [`plans/queue-engine.md`](queue-engine.md) — scheduler, store, and pause,
  resume, and halt background.
- [`plans/typed-queue-transcripts.md`](typed-queue-transcripts.md) — the
  transcript layer that Activity keeps.
- User-facing queue guidance in `docs/user-guide/` gains the search scope,
  Pause versus Stop All, retry, Overview versus Activity, and Not Reported
  behavior during implementation.
