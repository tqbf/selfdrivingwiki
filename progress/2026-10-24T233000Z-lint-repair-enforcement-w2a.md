---
timestamp: 2026-10-24T23:30:00Z
title: "Lint repair enforcement (W2a): breaker, patch budget, auto-revert, traceability"
branch: feature/generalized-page-validity-lint
status: complete
---

# Lint repair enforcement (W2a)

Repairs will become on-by-default. The shipped approval (`LintAcceptance/manifest.json`)
is public, so safety now comes from enforcement and reversibility. This work adds
that layer for selected-page lint runs. Whole-wiki lint stays report-only. No UI,
prompt, gate-matching, manifest, detector, or `PagePatchValidator` changes.

## Progress

- **`71aae72e` — CAS revert in the store.** `revertPage(pageID:to:expectingHead:)`
  checks the current head inside the same `mutate()` transaction as the repoint.
  A stale head throws `PageConflictError` and writes nothing.
- **`4bca60eb` — enforcement.**
  - `LintRepairBreaker` (WikiFSEngine): App Group `lint-breaker/`, one versioned
    JSON file per provider/model/effort. The pipeline digest is stored in the
    file, so a pipeline change resets the state in place. Window 10; 2
    verification failures or 2 user undos trip it. A tripped breaker demotes
    `.repairAuthorized` to report-only. Unreadable, forged, or unreachable state
    demotes and is never overwritten. `recordUserUndo` is the seam for the Undo UI.
  - Auto-revert: when post-write verification fails, the host reverts to the
    inspected head with the CAS revert. If the head moved, the host does not
    revert; it records the divergence and flags the page. `LintRevertOutcome` is
    a separate fact; the run stays failed.
  - `LintPatchBudget` (WikiFSCore): hunks and changed bytes per run, 3 hunks and
    2,048 bytes per confirmed repairable finding, floors 8 / 8,192, ceilings
    48 / 65,536. The daemon fixes the budget at the first minting read and checks
    it before the patch reaches the store. Over the cap: whole patch rejected,
    numbers recorded in `DaemonLintRunState` and a `--kind lint` entry, write
    phase closed. Host accounting reads the entry and sets `.budgetExceeded`.
  - Traceability: `LintAuthorityTier` + approval id + reason reach the plan, the
    dispatch outcome, the host audit line (`authority_tier=`, `approval_id=`,
    `authority_reason=`, `revert=`), `DaemonLintRunState`, and per-page queue
    report records (`QueueIngestionReporting.lintPageOutcomesMutation`).
  - Sandbox precondition: a lint launch without a lease manager is refused
    (`AgentLauncher.issueScopedRunIfConfigured`), and a lease always resolves
    the scoped seatbelt (`resolveSandboxInvocation`), which throws instead of
    failing open. Test: `LintEnforcementTests.unsandboxedLintChildCannotReceiveRepairLease`.

## Verification

- `make build` — pass.
- `make test` — pass (5,169 tests, 0 failures).
- `WIKIFS_APP_TESTS=1 swift test --filter 'Lint|AgentOperationRunner|DaemonLint|QueueReport'` — pass.
- bare `swift build` — pass.
- New suites: `LintRepairBreakerTests` (13), `LintPatchBudgetTests` (7),
  `LintEnforcementTests` (8), `DaemonLintBudgetTests` (3), plus 2 new
  `StoreEmissionTests`.
