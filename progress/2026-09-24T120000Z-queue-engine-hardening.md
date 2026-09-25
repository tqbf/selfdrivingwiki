---
timestamp: 2026-09-24T120000Z
title: Queue engine hardening (Tier 0 + Tier 1, all six phases)
branch: feature/queue-per-lane-status
status: complete
---

# Queue engine hardening (Tier 0 + Tier 1, all six phases)

## Progress

Implements [`plans/queue-engine-hardening.md`](../plans/queue-engine-hardening.md)
(committee consensus, 2026-09-24). Six phases, one branch + PR each, stacked
in order. The operator owns every merge.

### Branches (in merge order)

1. `bugfix/queue-claim-correctness` — pause-race-proof claims, stranded-claim
   repair, CAS store transitions, one-shot `getItem` test seam. Review
   follow-up commit: a mid-scan lane pause now stops only its own lane (the
   other lane's queued items still dispatch), plus wrong-state CAS coverage
   and assertion tightenings from review.
2. `bugfix/queue-settlement` — settlement-owned bookkeeping. `cancelItem` /
   `halt` keep the `runningTasks` entry; `handleWorkerFinished` is the single
   settle-once point (slot release + waiter resume on every path), fixing the
   live bug where `waitForCompletion` waiters on user-cancelled items were
   never resumed. Also fixes the `waitForCompletion` fast-path/registration
   TOCTOU found when the settlement suite wedged under full-suite load.
3. `bugfix/queue-bounded-waits` — bounded waits: engine
   `completionWaitDeadline` (35 min > 30 min manifest ceiling, ordering test
   pinned), daemon admission-drain deadline (60 s, injected deadline source,
   deficit accounting in `finishAdmission`). Review follow-up commit closes
   two HIGH findings: queued-item cancels now resume their waiters, and a
   halted dispatch's late settlement no longer releases a sibling's capacity
   (`releaseDeferredByRebuild`). Also carries the Phase 4 commit
   (daemon config mapping + follow-on engine wakeup + `try?` guard).
4. `feature/queue-per-lane-status` — per-lane menu-bar truth: per-lane
   membership dictionaries, per-lane pause tracking, tooltip lines naming
   each lane, synchronous icon re-derivation on lane resume. Also carries
   the Phase 5 commit (durable admission status + `wikictl queue` verbs)
   and the test-fix commit (admission-test subscription race; migration
   fixture schema delta for v10).

Note on PR stacking: Phases 3–5 sit on the Phase 2 branch, and Phase 6
sits on Phase 3 — merge in the listed order. PR #1321 (paused-lane
visibility) merges independently; Phase 6's `MenuBarItemController` changes
were written against main and will need a rebase over #1321 (both reshape
the same icon/tooltip derivation).

### Decisions recorded

- Cancellation contract: cooperative cancellation accepted and documented
  (extraction is manifest-deadline-bounded; ingestion settles via ACP
  launcher cancellation) instead of a cancel-path deadline race.
- Admission status is two nullable columns, not a new item state.
- Waiter truth: a lost terminal-transition race means waiters learn the
  item's terminal state (cancellation), not the worker's raw outcome.
- Known follow-ups are listed in the design note (admission re-check on
  catalog/credential changes; orphan-on-store-I/O-failure; deferred tiers).

## Verification

- `make build` green at every phase; `swiftlint lint --strict` — 0 violations.
- `make test` full suite green on the Phase 1 branch and again on the final
  stack (after the two starvation-driven time-limit failures were root-caused:
  one real engine TOCTOU — fixed; one test-control gate race — fixed by eager
  gate materialization; the new engine suites' time limits raised to 10 min
  to ride out full-graph continuation starvation).
- App-graph suites (`WIKIFS_APP_TESTS=1`): `WikiDaemonWorkloadHostTests`
  (incl. the new admission-drain expiry test), `ZoteroQueueExtractionProviderTests`
  (incl. the new engine-wakeup test), `QueueWorkspacePresentationTests`
  (incl. the new admission-chip mapping test), `MenuBarItemLintBlinkerTests`
  (incl. the new mixed-lane tooltip test).
- Read-only review subagents per phase; all CRITICAL/HIGH/MEDIUM findings
  fixed (Phase 1 MEDIUM lane-abort; Phase 2 HIGH queued-cancel waiter strand
  + HIGH halt sibling-capacity corruption + MEDIUM waiter-truth asymmetry).

## Decisions recorded

- Cancellation contract: cooperative cancellation accepted and documented
  (extraction is manifest-deadline-bounded; ingestion settles via ACP
  launcher cancellation) instead of a cancel-path deadline race.
- Admission status is two nullable columns, not a new item state.
- Waiter truth: a lost terminal-transition race means waiters learn the
  item's terminal state (cancellation), not the worker's raw outcome.
