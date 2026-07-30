---
timestamp: 2026-07-30T174300Z
title: Chat presentation Phase 1
branch: chat-presentation-diagnostics
status: complete
---

# Chat presentation Phase 1

Date: 2026-07-30T10:43:00-07:00

## Progress

The required plan is `bff24e5a900aec296a8de139915c6a559842474f`.
Implementation commit `4e7a779` makes provider transcript translation preserve
content-block boundaries. `LauncherChatAgentRuntime` has one typed open content
block. Compatible deltas update that block. Tool, role, user, failure, and
terminal events close it. A later assistant or reasoning block receives a new
message ID.

`ChatTranscriptReducer` now has a diagnostic reduction result. It rejects a
delta or replacement that reuses a message ID with a different turn or role.
The existing convenience reduction API returns the reduced items.

The follow-up commits are `4815c10` (initial progress record), `86a7169`
(progress-record contract), `b0e1015` (deterministic event-bus test delivery),
and `abe1797` (this corrective slice). `b0e1015` is retained: it changes only
the test wait from timing-based polling to a bounded condition wait, so it
removes a test race without changing product behavior.

The corrective slice updates the daemon persistence integration expectation to
the block-scoped generated IDs while retaining its one-assistant and
one-reasoning count checks. It adds deterministic characterization for two
terminal provider assistant blocks in one turn, duplicate terminal-event
idempotence, and reducer delta/replacement turn and role mismatches. It also
documents the two provider compatibility fallbacks: FIFO matching where tool
results lack a call ID, and generated role-turn-ordinal identity where provider
events lack a durable content-block ID.

## Audit disposition

- **H1 — fixed.** `DaemonChatControllerTests` now expects
  `assistant-<turn>-block-0` and `reasoning-<turn>-block-1`; its persistence
  no-duplicates count assertions remain in place.
- **M1 — rebutted.** The one-open-block state machine already closes at the
  Phase 1 semantic boundaries. The existing boundary tests plus the corrected
  terminal-provider characterization cover the claimed identity risk without a
  new data contract.
- **M2 — deliberately deferred to Phase 6 diagnostics.**
  `ChatClientSync.swift` and `ChatDomain.swift` still use the convenience
  reducer at their imperative-shell call sites, so anomalies are not yet logged
  with client context. The reducer safely preserves the existing item and
  exposes the typed anomaly. Surfacing it belongs with the correlated,
  redacted diagnostics sink in Phase 6; this slice does not add a partial
  logging convention or alter the Phase 2 sync wire.
- **M3 — fixed.** Swift Testing now covers delta turn mismatch, delta role
  mismatch, and replacement role mismatch, each asserting unchanged items and
  the exact typed anomaly.
- **L1 — retained.** `b0e1015` is a legitimate test-only race fix; focused
  `WikiEventBusTests` passes with the deterministic wait.
- **L2 — fixed.** Short comments explain why FIFO tool-result association and
  generated provider block identity are compatibility fallbacks.
- **L3, L4, L5 — rebutted for Phase 1.** They require no correction to the
  reviewed content-block translator or reducer contract. Work in their implied
  schema, active-block wire, display-row, WebKit, or diagnostics areas remains
  explicitly deferred to Phases 2–6.

## Verification

All commands below used `TZ=America/Los_Angeles`, `LANG=en_US.UTF-8`, and
`LC_ALL=en_US.UTF-8`.

1. Before the correction,
   `WIKIFS_APP_TESTS=1 swift test --filter DaemonChatControllerTests` ran 25
   tests and failed only at the two obsolete generated-ID assertions on lines
   709 and 713.
2. After the correction,
   `WIKIFS_APP_TESTS=1 swift test --filter DaemonChatControllerTests` passed:
   25 tests, including the persistence/no-duplicates guard.
3. `WIKIFS_APP_TESTS=1 swift test --filter LauncherChatAgentRuntimeTests`
   passed: 8 tests.
4. `swift test --filter ChatTranscriptReducerTests` passed: 8 tests.
5. `swift test --filter WikiEventBusTests` passed: 8 tests.
6. `make build` passed, including the SwiftPM build and signed app assembly.
7. `make test` was started but did not complete. After more than five minutes,
   a process sample showed
   `QuotaFallbackIntegrationTests.testSingleProviderQuotaFailsItem` blocked in
   `QuotaFallbackCoordinator.loadQuotaState()` at `Data(contentsOf:)` for its
   real persisted quota-state path. The test process was terminated. This is
   unrelated to this slice; it is not recorded as a pass.
8. `git diff --check` passed before the corrective code commit and again before
   the documentation commit.

No hosted AppKit view is exercised or changed in this slice, so the SwiftUI
runtime-issue log capture is not applicable. Mutation testing was not run.
