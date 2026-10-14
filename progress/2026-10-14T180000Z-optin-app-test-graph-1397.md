---
timestamp: 2026-10-14T18:00:00Z
title: Opt-in app test graph (issue #1397) — diagnosis and repair
branch: fix/optin-app-test-graph-timeouts
status: complete
---

# Opt-in app test graph, issue #1397: diagnosis + repair

## Progress

- Reproduced the full opt-in run (`WIKIFS_APP_TESTS=1 swift test --parallel
  --num-workers 1`): 19 failing tests across 15 suites, all inside the
  `WikiFSAppTests` bundle.
- Classified every failing suite with an alone-run: 12 fail
  deterministically in under half a second (test contract drift); 4 fail
  only under aggregate load (bounded waits too short for a contended main
  actor/pool; a strict 20ms GPU benchmark).
- The issue's "timeout signature" was queueing delay, not pool starvation:
  the failing tests do not block; they wait behind long hosted suites.
- Found a second harness defect: the `WikiFSAppTests` runner exits 0
  mid-run without a summary, silently dropping ~700 of 2855 planned test
  functions while `swift test` reports success (11 run-starts vs 10
  summaries; reproduced with the app bundle alone). No crash report, no
  jetsam kill. The false-green twin of #1398. Root cause unknown; needs
  dynamic tooling.
- Fixed all 12 drifted suites and hardened the 4 load-sensitive ones
  (Tests/ only, no Sources/ changes). Details in the PR for #1397.

## Verification

- Each repaired suite passes alone; the profiled fence-plan suite passed
  10 consecutive hammer runs.
- Full opt-in graph after the fix: all deterministic failures gone; the
  remaining red is the runner-death residual (unchanged from main).
- `make test` green on the branch (two unrelated pre-existing load flakes
  observed once each across four runs: a WikiFSCoreTests suite and
  QuitBackstopEndToEndTests — both in targets this branch does not touch).
