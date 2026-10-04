---
timestamp: 2026-10-04T053200Z
title: Offline semantic evidence recheck for review finding F3
branch: feature/wiki-strategies-cumulative-ingestion
status: partial
---

# Offline semantic evidence recheck for review finding F3

## Progress

This entry records the F3 delegate work for the independent review at
`tmp/claude-strategy-independent-review.md`. F3 flagged mixed live semantic
evidence: the repository scenario failed one check under an old heuristic, no
corrected-evaluator report existed for it, and no human rubric record existed.
The operator chose a bounded offline recheck over a fresh paid live run.

## What was built

A reusable offline recheck seam, not a fresh live run and not a new CLI binary:

- `StructuralCheck.requiresBeforeSnapshot` classifies which checks compare
  the before and after snapshots.
- `StructuralEvaluator.evaluate(check:after:)` re-evaluates one after-only
  check against one final-state snapshot. It returns nil for
  before-dependent checks.
- `OfflineRecheckRunner.recheck(...)` validates a recorded run, then
  re-evaluates. Guards, all failing loudly: the recorded file must be a live
  run; the scenario record must exist, be complete, and have delivered its
  strategy; recorded check ids and source filenames must match the current
  fixture code; the artifact database must exist; the artifact's recorded
  source filenames must map one-to-one onto the fixture stems. Fixture keys
  derive from the artifact database's own `sources.filename` rows. The store
  opens read-only through `GRDBWikiStore(readOnlyURL:)`.
- `WikiStrategyEvalRunner recheck --run <dir> --scenario <id>` runs it from
  the command line. Outputs land in `tmp/wiki-strategy-eval-recheck/<stamp>`,
  never inside the recorded run directory.

Before-dependent checks (`stablePageIdentity`, `noUnrelatedPageEdits`) carry
their recorded live outcomes forward unchanged, with the recorded run as
provenance. The recorded runs persist no before snapshot. No before snapshot
was invented.

## Result against the recorded 2026-10-03T002006Z artifact

Command: `swift run WikiStrategyEvalRunner recheck --run
tmp/wiki-strategy-eval/2026-10-03T002006Z --scenario
supersededRepositoryDecision`. Exit code 0.

Combined structural verdict: PASS. Seven checks re-evaluated offline under the
corrected evaluator, including `supersededInterpretation:Storage architecture`,
which the old heuristic had failed. Two checks carried from the recorded live
run. Output: `tmp/wiki-strategy-eval-recheck/2026-10-04T052548Z-supersededRepositoryDecision/`
(`recheck.report.md`, `recheck-results.json`). The report labels itself a
post-hoc recheck, not a live run.

Checksums of every file under the recorded run directory were identical before
and after the recheck. No paid call ran, and no live wiki database was touched.

Gates: `swift test --filter WikiStrategyOfflineRecheckTests` — 7 tests passed.
`swift test --filter WikiStrategyEvaluationHarnessTests` — 24 tests passed.
Full gates stay with the parent, after the F2 delegate work lands.

## Reviewer provenance claim, reverified

The review stated the provenance fix "was not re-verified with a fresh live
run". That claim is stale, reverified with direct read-only database queries:

- 232813Z original run, wiki `01M3ZF4RWEMCRDR73VAGTT3K43`, page "Mara Voss":
  head ref `page-content` points at version `01M3ZF9GV95CH10PT27WVMZM9C`,
  whose `page_version_sources` rows record only `meridian-chapter-07.md`
  (primary). This is the recorded real failure.
- 235350Z fresh live re-run, wiki `01M3ZGKP1BK5Z4EWD35FHF19MD`, page "Mara
  Voss": head ref points at version `01M3ZGSTT4R1C6Y1AX9RPC5M4P`, whose rows
  record `meridian-chapter-07.md` (primary) and `meridian-chapter-03.md`
  (supporting). The later live run did fix head provenance.

The 235350Z run predates the review. The reviewer inspected no artifacts and
could not see this. The earlier researcher report's reading of the recorded
outcomes is corroborated by the row-level evidence above.

## What remains

- The human rubric decisions. Packet: `tmp/wiki-strategy-human-rubric-packet.md`
  (six plan questions, exact passages, artifact identifiers, all decision
  fields pending). A human records Pass or Fail with a quoted passage. This
  delegate assigns no rubric score and does not claim F3 closed.
- The operator decides whether the offline recheck plus the recorded 8/9 live
  outcome is sufficient closing evidence for the repository scenario, or
  whether a fresh live run is required.
- Full gates (`make build`, `make test`, bare `swift build`, bare `swift
  test`) run with the parent after the F2 delegate work lands.
