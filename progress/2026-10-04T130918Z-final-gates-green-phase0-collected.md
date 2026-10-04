---
timestamp: 2026-10-04T130918Z
title: Final gates green after regression fixes and conceptual-audit context collected
branch: feature/wiki-strategies-cumulative-ingestion
status: complete
---

# Final gates green after regression fixes and conceptual-audit context collected

## Progress

This entry closes the loop on
`progress/2026-10-04T125722Z-final-gates-red-phase0-blocked.md`. Both
deterministic regressions are fixed, all five gates pass, and the
conceptual-audit Phase 0 context is collected. No Phase 2 audit ran here.

## Fixes

1. Commit `8c923ac1` — `fix(eval): open offline recheck stores through the
   StoreBackend factory`. The default `openStore` closure in
   `Sources/WikiStrategyEval/OfflineRecheck.swift` now routes through
   `StoreBackend.current.makeReadOnlyStore(readOnlyURL:)`, the existing
   read-only factory seam. The store still opens read-only. The Cordis
   allowlist and the boundary tests stay untouched, and no new
   concrete-store construction was added anywhere.
2. Commit `0faa6da4` — `docs(progress): restore Verification contract on
   gate-regression records`. Four progress entries gained honest
   `## Verification` sections, and the red-gates record gained YAML front
   matter and its own required headings. Recorded evidence is unchanged. No
   failure was relabeled as a pass.

## Gate outcomes at tested SHA `0faa6da4fee8b6950ec9b6cedb19703427cd6f64`

| Gate | Result |
|---|---|
| `make version` + `make prompts` parity | pass — no tracked drift |
| `make build` | pass — exit 0, app built and signed |
| `caffeinate -i make test` | pass — exit 0, 4758 tests in 10 targets, 0 issues |
| bare `swift build` | pass — exit 0 |
| `caffeinate -i swift test` | pass — exit 0, 4758 tests in 10 targets, 0 issues |

The two targets that failed before now pass: WikiFSCoreTests, 4375 tests in
453 suites (4 issues before, 0 now); CordisTests, 71 tests in 14 suites
(2 issues before, 0 now). The other eight targets passed as before: 190, 37,
29, 22, 12, 11, 7, and 4 tests.

Logs: `tmp/gates/rerun-make-version.log`, `rerun-make-prompts.log`,
`rerun-make-build.log`, `rerun-make-test.log`, `rerun-swift-build.log`,
`rerun-swift-test.log`, and the targeted runs `targeted-fix.log`,
`targeted-fix2.log`.

## Accepted opt-in gap, kept explicit

The operator accepts the known opt-in strategy menu template failure (6/7),
tracked as issue #1357 for a separate PR. That opt-in gap is not part of the
default suite above. The default full suite is green on its own. This run did
not hide, weaken, skip, or change that opt-in case.

## Collector

- HEAD: `0faa6da4fee8b6950ec9b6cedb19703427cd6f64`
- `origin/main`: `afb692d982a536072b702f11003bbf1eb633c1b5`; local `main`:
  `6fa4d5b9bba8a42959e3299e32efe23bc0b65f3a`
- Base used: `git merge-base origin/main HEAD` =
  `6fa4d5b9bba8a42959e3299e32efe23bc0b65f3a`, identical to the merge-base
  with local `main`. The value was computed, not assumed. The branch does
  not contain `afb692d9`.
- Command: `collect-pr-context.sh 6fa4d5b9... HEAD tmp/conceptual-audit`
- Artifacts in `tmp/conceptual-audit` (gitignored): `timeline.txt` (22
  commits), `pivots.txt` (0 candidates), `cumulative.diff` (21,869 lines),
  `stats.txt` (146 files changed, 18,711 insertions, 499 deletions).

## Verification

This entry reports direct command output. It verifies:

1. All five gates ran in sequence at `0faa6da4` with the outcomes and counts
   above. `make test` and bare `swift test` both reported 4758 tests and
   0 issues.
2. Targeted tests ran first and passed after the fixes:
   `DocumentationContractTests`, `CordisBoundaryScriptTests` (7 tests),
   and the 47-test filtered run covering `WikiStrategyOfflineRecheckTests`
   and `WikiStrategyEvaluationHarnessTests`. Exit code 0.
3. `git status --porcelain` was empty before and after every gate and after
   the collector. No foreign edits appeared. Nothing was stashed, deleted,
   pushed, merged, or rebased.
4. The collector script was read before execution. Its four outputs exist
   with the line counts above.
5. `DocumentationContractTests` re-ran green with this entry present, so the
   committed progress set satisfies the contract.

Scope limits, stated plainly: the full gates ran at `0faa6da4`. This entry
adds only this documentation file afterward. No conceptual audit (Phase 1 or
2) ran in this task, and none of its findings are claimed. The live app was
never restarted, no live wiki data was written, and no paid calls ran.
