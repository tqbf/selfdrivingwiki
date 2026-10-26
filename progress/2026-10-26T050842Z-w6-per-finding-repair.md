---
timestamp: 2026-10-26T050842Z
title: "W6: user-triggered per-finding lint repair (Fix / Edit Manually)"
branch: feature/generalized-page-validity-lint
status: complete
---

# W6: user-triggered per-finding lint repair (Fix / Edit Manually)

## Progress

The operator's design: when a lint run reports defects it did not repair,
each finding in Run Details gets **Fix** and **Edit Manually**. Fix runs a
targeted repair of that ONE finding. The click is the authorization, so
the rollout gate is not consulted. The full enforcement net wraps every
attempt. Production gate inputs are `.unconfigured` today, so autonomous
lint is report-only. Per-finding repair works anyway. The ladder section
in `plans/generalized-page-validity-lint-implementation.md` records the
new tier.

- **Tier and policy.** `LintAuthorityTier.perFindingRepair` and
  `ManagedRunPolicy.lintPerFindingRepair(pageID:)`: reads, CAS `page patch`
  on the assigned page only, lint log appends. Staging and every other
  mutation deny. The daemon gives the run one finding's patch budget.
- **Human-only requests.** The queue payload carries `LintRepairTarget`.
  The scoped-run guard refuses any scoped enqueue whose payload names that
  field, in every raw-frame shape. Without this, an ordinary managed child
  (it carries `wikiAcquire`) could mint the tier for itself.
- **Plan and run path.** `makePerFindingRepairPlan` scans the current head
  with the shared scan, takes the focus from that trusted scan, and refuses
  before launch (no write, no agent) when the head moved, the finding is
  gone, the class is not repairable, or the page is gone. The daemon queue
  provider runs the agent through the same launcher and the same
  `accountForLintRun`. Other hosts refuse by name.
- **Enforcement (reused).** Coverage validation, the written-head compare,
  ONE guarded CAS revert, and the host audit line are unchanged.
  `LintPerFindingScope` adds one rule on top: a write must resolve its
  target, and no other finding outside the target's bytes may change.
- **Breaker key at launch.** `AgentLauncher.lastLaunchedConfiguration`
  records what the launcher spawned. The key is the live pipeline digest
  plus that provider/model/effort. It goes into the record as
  `breaker_key=`, so the W2b Undo records its user undo under the same key.
  If the lint model cannot start, the item fails with a named error that
  points at Settings.
- **Prompt.** `{{findingSection}}` renders `lint-page-per-finding.md` and
  ONLY the target class's entry from the new per-class playbook
  `lint-repair-playbook.md` (operator design addition). The template edit
  moved the pipeline prompt hash from `317b43…` to `c37d04…`. The manifest
  pipeline block was regenerated with `WikiLintEvalRunner manifest` and its
  approval rows stay empty. This invalidates earlier acceptance-key
  evidence. No approval rows existed, so nothing is lost.
- **UI.** Run Details finding rows gain a controls row: Fix, Edit Manually
  (the existing target routing plus the per-tab editing flag), an honest
  status line, and Show Fix Run. `QueueLintFindingFixState` derives each
  state from the queue snapshot, the fix runs' durable records, and the
  window's click-local state, which resets on selection change. The
  report-only line now says repairs are user-triggered per finding.

Undo interplay: a per-finding run's surviving write is repair-capable, so
`wroteSurvivingRepair` holds and the W2b Undo section renders in the fix
run's own Run Details. A reverted write renders the disclosure instead.

## Verification

GATE_RESULTS_PLACEHOLDER
