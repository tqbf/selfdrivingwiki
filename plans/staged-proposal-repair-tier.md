# W5a — Staged-proposal repair tier: engine, daemon, store

Status: engine/daemon/store complete; the review UI is a follow-up assignment keyed to the record shapes below.

## The ladder

Acceptance evidence is an optimization, not a gate. Three tiers:

1. **Tier 1 — silent repair.** A shipped approval row matches; repairs write directly, with Undo, breaker, budget, and auto-revert (W2a).
2. **Tier 2 — staged proposals.** ANY unevaluated configuration still lints and fixes, but hunks are staged, never written. A human reviews the projected diff and approves; approval applies the exact hunks through the same enforcement net.
3. **Tier 3 — report-only.** Always reported, everywhere. A degradation outcome, not a default.

## Selection (schema 3)

`LintAcceptanceManifest` schema 3 removed `defaultReportOnly`; "enabled" is whether approval rows exist. `LintRolloutSelection` is three-way, checked in order — first match wins:

| # | Condition | Selection |
|---|-----------|-----------|
| 1 | Manifest missing/unreadable/undecodable/structurally invalid | `.reportOnly(reason:)` |
| 2 | Row matches (provider/model/effort) AND pipeline equal AND revision rule passes | `.repairAuthorized(approvalID:)` |
| 3 | Row matches but pipeline drifted or revision changed | `.stagedProposal(reason:)` — a stale approval downgrades to review, not to nothing |
| 4 | No matching row | `.stagedProposal("configuration not yet evaluated — repairs staged for your review")` |

Guard test: a shipped manifest with non-empty approvals MUST match the live build pipeline (inert while rows are empty).

## Tier-2 breaker

- Demotion: `.stagedProposal` + tripped breaker → report-only ("proposals paused for this configuration…"). A missing key demotes the same way.
- Keys are NOT approval-row-driven: `LintRepairBreakerKey(live pipeline digest, provider, model, effort)` directly — tier 2 has no row by definition.
- Recording is ACTIVE for tier 2: `verificationFailure` (post-apply), `userUndo` (W2b service), and the new `userRejected` (two in the window trips, same as undos). `recordUserRejected(for:)` is the trusted-host seam.

## Staging seam

- `ManagedRunPolicy.lintSelectedPageProposal(pageID:)`: read-only classes, one allowance — `page propose-patch` against the pinned page. It can never patch; tier 1 can never propose; a payload marker cannot swap the tier (the guard reads the lease's policy).
- `page propose-patch` mirrors `page patch` on the wire (`DaemonPageProposePatchRequest`) and in the CLI (shared `parsePatchForm`). Daemon interception under the proposal policy: current receipt required; budget checked with the patch path's mirror (rejection closes the run + audit entry); the SAME `PagePatchValidator` rules run against the current body; then stage, never write. At most ONE proposal per page per run (`alreadyStaged` refusal).

## Staged-proposal record — the review UI's contract

`DaemonLintStagedProposal` (daemon run state; survives run teardown):

| Field | Meaning |
|-------|---------|
| `id: String` | Stable reference (ULID). Per-page records carry it as `staged_proposal=<id>`; the apply service takes it. |
| `runID: DaemonRunID` | The run that staged it. |
| `pageID: PageID` | The page it targets. |
| `stagedAt: Date` | When the daemon accepted it. |
| `inspectedHead: PageVersionID` | The head the hunks were composed against (CAS expect-head at apply). |
| `bodyFingerprint: String` | The inspected body's fingerprint (diff provenance). |
| `hunks: [PagePatchHunk]` | The exact ranged edits. |
| `perHunkClasses: [LintDefectClass]` | Parallel to `hunks`. |
| `status: .staged` | A staged record is immutable; later states live in outcomes. |

Read seams: `stagedProposal(runID:pageID:)`, `stagedProposals(pageID:)` (newest first across runs). Durable audit trail (trusted `--kind lint` entries): `Lint proposal staged — <title>` with note `proposal_id=…; inspected_head=…; body_fingerprint=…; hunks=N` (parsed by `LintProposalAudit.parseStagedNote`), and `Lint proposal applied — <title>` with note `proposal_id=…; outcome=applied|applied-then-reverted|stale|failed; …`. Host accounting folds `proposals=N; staged_proposal=<id>` into the per-page record; `LintPageRecordFacts.proposalCount` / `.stagedProposalIDs` parse it — the UI's "N proposed" data source.

## Apply-on-approve

`LintProposalApplyService` (trusted app side, `LintUndoService`'s shape). Input: a mapped proposal (`id, pageID, inspectedHead, bodyFingerprint, hunks, perHunkClasses`) + approved hunk subset (nil = all). Order: stale gate (head ≠ inspected head → `.stale`, nothing written, breaker untouched) → budget re-check → `WikiStore.patchPage` exact-body CAS (no new mutator; `mutate()` emission free) → W2a written-head verification over store-observed change ranges → failure: one CAS auto-revert + `verificationFailure` recorded + disclosure data retained. Outcomes: `applied` / `appliedThenReverted` / `stale` / `failed`. Rejection: `recordRejection(breaker:breakerKey:)`.

## Prompts

`prompts/lint-page-task.md` gained `{{tierSection}}` (the only prompt edit): tier 1 renders empty (patch text unchanged); tier 2 renders the staging discipline — propose-patch command with the run's page id, one-proposal-per-page rule, `unresolved|staged proposal <id> awaiting human review` report mapping, `verification none`. All validity-scope rules unchanged; system prompts stay lint-free (AC.1). The shipped manifest's pipeline was regenerated for the new prompt hash; rows stay empty.
