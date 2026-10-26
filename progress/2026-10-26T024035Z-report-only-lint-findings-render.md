---
timestamp: 2026-10-26T024035Z
title: Report-only lint runs render their detected findings
branch: feature/generalized-page-validity-lint
status: done
---

# Report-only lint runs render their detected findings

## Progress

The operator ran a selected-page lint the production rollout gate
refused to let repair (authority tier `reportOnly` — gate inputs
unconfigured, the known tracked gap). The page was correctly untouched,
but no findings report was visible anywhere except the raw activity
log line: plan §5.10/§5.14 expect report-only runs' findings to render
in the existing Run Details surfaces.

Two gaps, both fixed:

1. **Data (the deeper one).** The host accounting
   (`AgentOperationRunner.accountForLintRun`) folded only the
   UNRESOLVED finding ids into the per-page record detail; class
   labels, counts, evidence, and the valid-as-written /
   outside-scope outcomes never persisted. The accounting now appends
   what the trusted pre-flight scan detected — `findings=<total>` plus
   one `finding=<id> <class> <outcome>[ evidence=<text>]` segment per
   detection (`LintPageRecordFacts.findingsDetail`), evidence
   sanitized so the `"; "` grammar stays unambiguous — and
   `LintPageRecordFacts.parse` reads the labels back (`findingCount`,
   `findings`, plus the previously unparsed `authority_reason`). A
   detection without a report outcome records `unreported`; a legacy
   record without the labels parses `findingCount == nil`, so absence
   stays distinguishable from an honest zero.

2. **UI.** The Run Details panel grew a detected-findings section
   (`QueueRunDetailsLintFindings` value model + rows in
   `QueueRunDetailsView`, wired in `ActivityWindowView` like the
   repair and proposal sections): the total (or "none detected"), a
   per-class counts row, one row per finding (class label, outcome,
   evidence), and — when the records name a report-only tier — the
   honest line naming the recorded reason and that repairs need an
   approved configuration or staged-proposal review. Legacy records
   render no section; nothing is invented.

Repair-authorized runs' records carry the findings labels too, and the
section renders them the same way — the detected facts are true of
every lint run, not just report-only ones.

## Verification

- `LintUndoServiceTests` (producer/parser): a real scan's findings
  produce and re-parse the labels; evidence `;` flattening pinned;
  `findings=0` vs legacy-absence pinned; `finding=` segments close
  verification-reason continuations.
- `LintEnforcementTests`: a report-only run over a defective page
  records every detection (class, outcome, evidence) with nothing
  written; a clean page's report-only record carries `findings=0`.
- `LintFindingsSectionValueTests` (value model): mapping, per-class
  counts, clean-zero visibility, legacy/non-lint/whole-wiki nil, the
  report-only line's exact wording, repair-tier records render without
  the reason line.
- `LintRunDetailsScenarioTests` (hosted): the findings section mounts
  in a real window — counts + labels + reason for a damaged page,
  "none detected" + reason for a clean one.
- Gates: `make build`; `WIKIFS_APP_TESTS=1 swift test --filter
  'Lint|QueueReport'` (39 + 197 + 124 tests green); `make test` full
  suite; bare `swift build`.
