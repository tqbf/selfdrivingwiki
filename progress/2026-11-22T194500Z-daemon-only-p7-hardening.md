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

- **Zero waivers verified.** `AppStoreFreedomContractTests`,
  `FileProviderStoreFreedomContractTests`, and
  `WikiCtlStoreFreedomContractTests` pass with EMPTY waiver lists (the
  final waiver — the File Provider's read-only DB opens — cleared at
  P6). `wikictl-fixture` stays the sole documented carve-out.
  `ClientLocalOpenBoundaryTests` asserts zero client-side store,
  read-pool, queue, provider, and index-build opens with the daemon up
  and down.
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
  + error mapping — plan item 7.5) — results recorded in the plan's
  P7 verification record.

## Verification

- `make test`: 4,717 tests in 493 suites, 0 issues (with the flake
  fix and all P7 changes in).
- `make lint`: 0 violations.
- `SESSION_OPEN_BENCHMARK=1 swift test --filter
  SessionOpenLatencyBudgetTests`: all four metrics within budget.
- `swift test --filter DocumentationIndexContractTests`: 3/3.
- Per-phase progress notes: P1, P3, P4, P5 (in-repo); P2, P6 recorded
  in their commit messages.
