---
timestamp: 2026-10-25T061614Z
title: W4a docs amendment — the amended trust ladder recorded in the written record
branch: feature/generalized-page-validity-lint
status: complete
---

# W4a docs amendment — the amended trust ladder recorded in the written record

## Progress

Docs-only. The written record now matches the shipped design: the operator's
amended trust ladder (tier 1 silent repair for shipped-approval
configurations, tier 2 staged proposals for ANY unevaluated configuration,
tier 3 report-only for degradation only) replaced "the eval gate authorizes
repairs" everywhere the old wording implied gate-as-precondition. No source
changes.

- `plans/generalized-page-validity-lint-implementation.md` — rewrote the
  rollout/gate material into "The amended trust ladder (what ships)": the
  three tiers with `LintRolloutSelection` case names, the schema-3
  `LintAcceptanceManifest` (pipeline block + evidence + approval rows;
  `defaultReportOnly` removed; "enabled" = rows exist; the
  shipped-pipeline-equals-live-build guard test), the approval-minting flow
  (`WikiLintEvalRunner manifest` + operator review; the plan's original
  live-eval discipline still applies to a row), and the enforcement
  machinery with file pointers (`LintRepairBreaker` window 10 / trips at 2
  and demote-only, `LintPatchBudget` 48 hunks / 65,536 bytes per run and
  2,048 per confirmed finding enforced at staging AND apply, CAS
  `revertPage`, `DaemonLintStagedProposal` one-per-page staging,
  `LintProposalApplyService`, `LintUndoService`,
  `QueueRunDetailsLintProposals`, `LintRunMode`). Replaced the AC.13/AC.14
  wording: acceptance evidence buys zero-ceremony authority for that
  configuration (not a precondition for repair), unevaluated configurations
  run tier 2 by default, report-only stays degradation-only. The commit
  table gained the W2a/W2b/W4/W5a/W5b rows.
- `plans/cli-domain-commands.md` — new "Page propose-patch (the tier-2
  staging path)" section: same hunk JSON contract as `page patch`,
  `--expect-head` required, daemon-side validator parity + budget, one
  proposal per page per run, staging survives run teardown, review/apply
  through `LintProposalApplyService`.
- `plans/agent-sandbox-scoping.md` — the lint operation policies section now
  lists five policies (the `lintSelectedPageProposal(pageID:)` tier-2
  policy: reads + lint log + `page propose-patch` on the pinned page ONLY;
  `page patch` denied), and the gate sentence describes the three-way
  selection with the fail-closed `DaemonLintPolicyTests` matrix row.
- `plans/generalized-page-validity-lint.md` — NOT rewritten (approved
  requirements stay as approved). Added one factual cross-reference line to
  the Status block pointing at the implementation doc's amended-ladder
  section; the existing status-block and in-body plan-link style supports
  it.
- `PLAN.md` — the lint implementation index row now describes the amended
  ladder and the staged-proposal/review UI work; the W5a row's "review UI
  pending" tail now records the landed `QueueRunDetailsLintProposals`
  review section.

Hosted-scenario harness limits (recorded in the W2b/W5b notes; restated in
one line each for consistency): the Run Details List defers materializing
trailing rows, so hosted clicks need `scrollRowToVisible` first; buttons
need their own List row to bridge to AppKit (a synthesized row-center click
lands on the row's spacer, not the control); `NSHostingView.rootView` hands
back a pre-install struct copy whose `@State` never attaches, so scenarios
observe state through a published sink.

## Verification

- `swift test --filter DocumentationContractTests` — 16 tests in 2 suites
  passed (includes `progressEntriesFollowTemplate`).
- `make build` — passed (app built and signed).
- Full source diff for this unit: none (docs-only assignment).
