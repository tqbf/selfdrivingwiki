---
timestamp: 2026-11-22T194500Z
title: Daemon-only P7 hardening — zero waivers, budgets, docs
branch: feature/daemon-only-p1-async-store
status: active
---

# Daemon-only P7 hardening — zero waivers, budgets, docs

## Progress

Phase 7 (plan `plans/daemon-only-access.md` P7 column) closes the
migration on `feature/daemon-only-p1-async-store` (with P6, committed
as `a1aefb98`).

- **Zero client opens verified.** The app TARGET (`Sources/WikiFS`) and the
  File Provider carry zero forbidden tokens (the File Provider's waiver
  list cleared at P6); three documented permanent tier-shared entries
  remain in app-reachable WikiFSEngine composition files that also serve
  the daemon/CLI/test `.local` compositions.
  `ClientLocalOpenBoundaryTests` asserts zero client-side store,
  read-pool, queue, provider, and index-build opens with the daemon up
  and down — the runtime proof.
- **Golden master** green against the committed P0 baseline artifact
  (state + event sequence) on the post-P6 build.
- **Performance budget** within ≤ 1.25× everywhere — all four metrics
  at or UNDER the P0 baseline (session open cold median 4.1 ms vs
  4.3 ms; page open 0.0 ms vs 0.2 ms; sidebar search 0.0 ms; queue
  round trip 0.1 ms vs 0.2 ms).
- **Docs finalized.** `plans/daemon-only-access.md` carries the final
  waiver history and P7 verification record; `plans/multi-wiki-daemon.md`
  gained its sole-writer superseded note; the new
  `DocumentationIndexContractTests` (AC.12) machine-checks the PLAN.md
  index entry and the superseded markers.
- **Test-embedder seam flake fixed** (introduced at P5, evidence in
  tmp/seam-trace.log): the ungated
  `DaemonFusedSearchTests.embedderFailureDegradesToLexicalOnly` stomp
  was the interleaver — os_log captured `install
  new=keyword-fixture-4 old=stub-test-2` mid-window. The seam gate now
  uses ownership tokens (stale deferred releases are ignored), every
  seam call site claims the gate, and the previously ungated tests
  were gated. The filter repro loop (2/3 failing before) is 3× green;
  the full suite is green.
- **Mutation testing** on `Sources/WikiDaemonContract` (the wire codec
  + error mapping — plan item 7.5): 56 mutants, score 100.0% (56 killed,
  0 survived, 0 no-coverage), scoped to the opt-in app-host integration
  suites — full record and the sandbox environment notes in the plan's
  P7 verification record and `.swift-mutation-testing.yml`.
- **Post-hardening defect repair (P6, exposed by two new suites).**
  `ProjectionBoundedQueryTests` and `ProjectionLargeContentTests` pin the
  P6 socket-fixture contracts (AC.11): the #291 one-ReadScope-per-pass
  bound, and chunked `> 4 MiB` content fetch. The bounded suite exposed a
  real regression — one enumeration pass over 13 rows issued 267 wire ops
  (per-view page renders recomputed, and the first token assignment
  mid-scope discarded caches the pass had already built). The fix: caches
  for full listings, page renders, and verbatim source bytes on
  `ReadScope`; token invalidation only when an already-cached token
  changes. The pass now issues 193 ops (root 13→7, working set 112→51),
  and the suites encode the honest per-pass budgets. The large-content
  suite exposed a second defect: `payloadRead` chunk replies went through
  the ordinary 256 KiB inline threshold, so every 1 MiB chunk re-stashed
  as an oversized handle and the client download loop recursed to its
  10 s deadline. Chunks now return inline against the 4 MiB frame cap;
  the 5 MiB fetch returns exact bytes in ~0.2 s.

## Verification

- `make test`: 4,717 tests in 493 suites, 0 issues (with the flake
  fix and all P7 changes in).
- `make lint`: 0 violations.
- `SESSION_OPEN_BENCHMARK=1 swift test --filter
  SessionOpenLatencyBudgetTests`: all four metrics within budget.
- `swift test --filter DocumentationIndexContractTests`: 3/3.
- Guarded runner, the two new P6 suites
  (`scripts/test-optin-app-tests-reconciled.sh --filter
  "ProjectionBoundedQueryTests|ProjectionLargeContentTests"`): 2/2.
- Guarded runner, the six existing FP suites through the real socket
  fixture (`ProjectionTreeTests|EnumeratorStoreFailureTests|
  EnumeratorDeletionTests|ZeroByteSourceProjectionTests|
  FileProviderReimportCreateTests|WikiStrategyProjectionTests`): 93/93.
- Per-phase progress notes: P1, P3, P4, P5 (in-repo); P2, P6 recorded
  in their commit messages.
