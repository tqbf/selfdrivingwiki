# W7 — Interactive lint: foreground, single-flight, modal results dialog

Branch `feature/generalized-page-validity-lint` (in sync with origin). Conventional Commits per logical unit. Never push, never merge. Anti-stall: commit per unit; `BLOCKED:` section if stuck 10+ minutes.

## The operator's design

Lint stops being a background queue activity. It becomes **interactive**: the user invokes it from the page they're on, **exactly one lint runs at a time**, and the run **must end in a modal dialog** that shows either the findings (each with Fix / Edit Manually actions) or a clean bill of health. No silent background lint, no queue entry points for the user.

## Established facts (read these files first)

- The W6 per-finding repair flow (commits 8e7b6c7f…e33d12e5) established the FOREGROUND path: `makePerFindingRepairPlan` + the app's daemon proxy execution, `LintAuthorityTier.perFindingRepair`, policy `.lintPerFindingRepair(pageID:)`, and the Fix/Edit buttons in `QueueRunDetailsLintFindings`/`QueueRunDetailsView` + `ActivityWindowView` state. The interactive lint service should follow this foreground precedent — NOT queue ingestion.
- Queue lint paths today: `AppQueueIngestionProvider` / `DaemonQueueIngestionProvider` lint handling, `AgentOperationRunner.makeLintPagePlan`, queue report records (`QueueIngestionReporting.lintPageOutcomesMutation`), the Activity window surfaces (W2b repair/undo, W5b proposals, W5c findings sections all read from queue-run records).
- The findings data path (W5c): durable per-page records carry `findings=<N>` + per-finding segments; `LintPageRecordFacts` parses them.
- Production gate inputs are `.unconfigured` → runs are report-only today; the interactive lint is a DETECTION pass (report-only policy is correct and honest for it) — fixes happen per-finding afterward via the W6 flow.

## Target design

### 1. Interactive lint service (single-flight, foreground)

- New app-side service (e.g. `InteractiveLintService`): invokes the selected-page lint for ONE page through the foreground coordinator/daemon path (the W6 precedent — scoped lease, real coordinator, report-only policy). NOT via queue ingestion.
- **Single-flight**: one lint at a time app-wide. While a lint (or a per-finding fix from its dialog) is in flight, the Lint action is disabled with an in-flight indicator. This is a finite state machine per the repo modeling rules: `idle → running(page) → presenting(result) → idle` — not a bool cluster.
- Cancellation: allow the user to cancel an in-flight lint (bounded async termination per repo rules — no cooperative-pool blocking).

### 2. Entry point

- A **Lint** action in the page context — find the natural home (the page editor's toolbar/menu or the page-level command surface; follow the app's existing command patterns). Enabled only when a page is open and no lint/fix is in flight.

### 3. The modal results dialog

- On completion, present a **sheet** on the page window (macOS sheet, system typography, repo design skills apply):
  - **Findings present**: the findings list — per finding: class label, location/evidence, and **Fix** / **Edit Manually** buttons (reusing the W6 per-finding machinery: Fix launches the targeted one-finding repair with verification + auto-revert + breaker; Edit opens the editor). Rows update live: fix applied → repaired (undo available via the established undo path); verification failure → reverted + what verification caught; page-changed → honest message.
  - **No findings**: a clean bill of health — "No validity defects detected." (plus the report-only honesty line if the run was report-only: findings are reported, not repaired).
  - A run-level line stating the outcome honestly (report-only reason when applicable).
- The dialog does not auto-dismiss; the user closes it. The run remains in the durable record (activity log/Run Details still show history — those surfaces stay for the record; the modal is the interactive moment).

### 4. Queue lint entry points: remove the user-facing path

- Remove the UI surfaces that enqueue lint as background queue work (the operator's directive: lint is interactive now). Keep the underlying machinery the eval harness and records depend on (daemon lint handling, report records, the W2b/W5b/W5c Run Details sections — history rendering stays). Audit for dead UI code and remove it with its tests, updating the tests that asserted queued-lint UI behavior.
- Whole-wiki lint (report-only, batch) is OUT OF SCOPE — leave it exactly as is.

### 5. Docs

- Implementation doc: the interactive lint flow (service, single-flight, dialog) replaces the queued lint UX; the ladder section notes lint is user-triggered and interactive. Progress note per template.

## Tests (Swift Testing)

- Service: single-flight enforcement (second start refused/queued-out while running), cancellation terminates cleanly, report-only policy used, findings/none mapped to dialog states.
- Hosted dialog scenarios: findings present → sheet with rows + Fix/Edit; clean → bill of health; Fix from the dialog → verification flow → row updates (reuse the W6 hosted patterns); no AppKit-bridging buttons-in-one-row (own rows); `.serialized` + `.timeLimit` for hosted suites.
- Removal: tests that asserted queued-lint UI entry points are updated/removed honestly.
- Parser/records untouched (W5c data path reused as-is).

## Gates

`make build`, `make test`, `WIKIFS_APP_TESTS=1 swift test --filter 'Lint|QueueReport|AgentOperationRunner'`, bare `swift build`.

## Report shape

(1) Files changed, one line each. (2) The user flow as implemented (entry → in-flight → dialog states → fix interactions). (3) What queue-lint surface you removed and what history you kept. (4) Gates + counts. (5) Deviations + why. (6) Commit hashes.