---
timestamp: 2026-10-25T190244Z
title: W4c3 round-three lint items finished
branch: feature/generalized-page-validity-lint
status: complete
---

# W4c3 round-three lint items finished

## Progress

Landed the three round-three re-review items (two defects plus one
test-enablement) on the lint staged-proposal work, one commit each.

- Item 1 (HIGH, 5858e5c5): the tier-2 repair-claim rejection only
  inspected `finding` rows, while coverage validation accepted either
  row kind against one combined inventory+finding ID set — so
  `item D08-1 repaired` covered the finding and slipped past the gate.
  Tier 2 now rejects every `.repaired` entry regardless of row kind,
  and `LintCoverageValidator` splits the expected set by kind:
  inventory IDs are covered only by `item` rows, finding IDs only by
  `finding` rows. Both rename directions are rejected; kind-aligned
  honest reports still complete.
- Item 2 (HIGH, 2e3b01f8): `LintHistoryFacts.load` reports read
  failures through `.readFailed` instead of throwing, so a failed D27
  history read never reached required-checks availability. All three
  availability derivations (the proposal apply scan, the pre-run plan,
  and the tier-1 written verification) now gate on `.readFailed`. A
  blocked history check fails verification and runs the recovery path
  (guarded revert + breaker evidence).
- Item 3 (test enablement, 880c105c): the no-fallback Approve-all
  interaction test now uses Swift Testing's conditional disable keyed
  on `WIKIFS_INTERACTION_TESTS=1` (the same convention as the ACP
  smoke flag). Without the flag it skips with an actionable reason;
  with it, the standalone press passes — the real control writes both
  staged hunks. The flag is documented in the test's comment and here.

A fixture-design discovery worth keeping: blobs are content-addressed
and deduplicated by hash, so two versions with byte-identical bodies
share one blob row — deleting "the parent's blob" then also destroys
the head's body. The history-fault fixtures therefore append a
byte-different second version before sabotaging the parent blob.

## Verification

- `make build` — green.
- `make test` — green (full suite).
- `WIKIFS_APP_TESTS=1 swift test --filter
  'Lint|PagePatch|DaemonLint|DaemonScope|QueueReport|AgentOperationRunner'`
  — green (162 tests, 22 suites).
- bare `swift build` — green.
- New tests: `rejectsCrossKindRowsAndAcceptsKindAlignedOnes`,
  `tier2RepairClaimsOnItemRowsStayRejected`,
  `tier2HonestUnresolvedReportIsAccepted`,
  `historyReadFailureFailsApplyClosedThroughTheRecoveryPath`,
  `planDerivationMarksBlockedHistoryCheckUnavailable`,
  `historyReadFailureAtAccountingFailsVerificationAndRecordsBreaker`.
- Opt-in interaction flag: `WIKIFS_APP_TESTS=1
  WIKIFS_INTERACTION_TESTS=1 swift test --filter
  approveAllInteractionPressesTheRealControl` passes standalone
  (0.97s, both hunks written through the real control). The same flag
  over the STACKED 22-suite filter run fails exactly on the documented
  press-delivery limitation (4 issues, all in this one test; the other
  161 tests pass) — kept opt-in rather than un-disabled, per the
  contract.
