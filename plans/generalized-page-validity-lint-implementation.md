# Generalized page-validity lint — implementation

Status: **phases 0–6 complete and committed; the W2/W4/W5 units are landed
(enforcement, reversibility, the shipped-approval manifest, staged proposals,
and the review UI). This document records HOW the requirements were implemented
and where each piece lives.** Requirements live in
[`generalized-page-validity-lint.md`](generalized-page-validity-lint.md).
Branch: `feature/generalized-page-validity-lint`.

> **Design amendment (operator decision, 2026-10-25).** The rollout gate no
> longer authorizes repairs by evaluation. "Eval-as-gate" is retired. The
> shipped design is the amended trust ladder below: an evaluated configuration
> repairs silently, ANY unevaluated configuration lints and stages its hunks
> for human review, and report-only is reserved for degradation. The ladder
> section supersedes every older gate description in this document and in the
> commit table.

## What landed (committed, full suite green after each)

| Commit | Phase | Contents |
|---|---|---|
| `ca7de2f2` | 0 | System-prompt lint removal; self-contained `lint-page-task.md`; coherent `PageCoherentRead`; bracket fix under CAS with honest reporting |
| `117c9be4` | 1 | Shared parser foundation (`ParsedMarkdownDocument`, AST code protection, `MarkdownFenceFacts`, footnote analysis); typed lint records; pure `LintPagePreflight` with inventory + first detectors |
| `b5e6c036` | 2 | `ManagedRunPolicy` (ordinary / selected-page repair / selected-page report-only / whole-wiki report-only) through lease→broker→registry→grant; lint allowlist (reads + kind-conditioned log append only); `DaemonLintRunState` CAS budget |
| `3fdc97be` | 3 | `wikictl page patch` (strict `--hunk`/`--defect` alternation, `--hunk-file`), atomic `WikiStore.patchPage` in exact-body mode, provenance union, citation/quote integrity, daemon wire, event semantics |
| `ebd81230`/`d43555f0`/… | notes | Progress notes per stretch |
| `de0e7437` | 4 | **Complete v1 detector coverage** (D01–D28 in-scope): fence closures, delimiter parity, table shapes (source-counted rows), indent jumps + accidental indented code, heading jumps/duplicates, placeholders, merge markers + 80-char duplicates, encoding, active content, reference labels + scheme-less media, truncation, meta-text, double entities/bidi, history regression vs the ACTUAL parent (30% shrinkage), rich-fence re-validation. Injected facts (`LintCitationFacts`, `LintOriginURLFacts`, `LintHistoryFacts`, `LintFenceValidationFacts`) keep the scan pure; missing facts record honest limits. Async `detailedFenceValidation` on `FenceSyntaxValidationService` (validated/invalid/unclaimed/suppressed/unavailable). Detector revision `lint-preflight-v2`. |
| `ddfe43f6` | 5a | REQ-29 ten-check model, fixed run-report format + strict parser, REQ-31/32 coverage validator, REQ-54 `LintVerification.compare` |
| `5bd10c7e` | 5b | Typed identity + staged `LINT_PREFLIGHT.md`/`LINT_RUN_REPORT.md` artifacts; shared per-page plan builder; sequential per-page dispatch (app UI, app queue, daemon queue); observed per-page queue outcomes |
| `17105b0b`/`e824e9a3` | 5c | Daemon snapshot receipts wired (mint on selected JSON read, validate on patch, invalidate on commit, two-conflict close); AC.5 live sandbox test |
| `6280f47c`/`a492b0b5` | 5d | Host `--kind lint` audit log (agent-log detection); REQ-54 full compare with store-observed change regions; daemon written-version verification records |
| `be711293` | 6a | `WikiLintEval` harness: fixture manifests, diff oracle, per-class scoring; shipped `LintGateFixtureManifest.json`; `WikiLintEvalRunner` (inspect/replay/live-refusal); 9 harness tests |
| `4d4d07b9` | 6b | Rollout gate wired into the coordinator (per-machine acceptance records at the time; the design since changed — see the ladder section) |
| `1e5bd9c0` | W4 | The rollout approval ships as a bundle manifest: `LintAcceptanceManifest` + `LintAcceptanceGate` structural matching over the SHIPPED resource; retired the per-machine `LintAcceptanceRecord` and its write path. First ship was schema 2. |
| `359d07e2` | W4 | `WikiLintEvalRunner manifest` subcommand mints approval candidates (pipeline block from the live build + `--approval` rows + evidence flags; validated, printed or written under `tmp/` only) |
| `4bca60eb` | W2a | Enforcement for on-by-default repairs: circuit breaker, patch budget, post-apply verification, auto-revert accounting |
| `71aae72e` | W2a | Expected-head CAS form of `revertPage` (`revertPage(pageID:to:expectingHead:)`) |
| `f6c4c815` | W2b | One-click Undo and the "What went wrong" disclosure in Run Details (`LintUndoService`, `LintPageRecordFacts`, breaker context line) |
| `a119c6bc` | W5a | Three-way gate: `LintRolloutSelection.stagedProposal(reason:)`; manifest schema 3 (`defaultReportOnly` removed; "enabled" = rows exist) |
| `0d8753d8` | W5a | Breaker wired for the staged-proposal tier: `userRejected` joins the trip rules; tier-2 keys need no approval row |
| `e968acf0` | W5a | `ManagedRunPolicy.lintSelectedPageProposal(pageID:)` — the tier-2 lease policy (reads + lint log + `page propose-patch` on the pinned page only) |
| `4bce515e` | W5a | `page propose-patch` staging in daemon run state (`DaemonLintStagedProposal`; validator parity, budget mirror, one proposal per page per run) |
| `0ccecec0` | W5a | Tier-2 runs through the coordinator, the `{{tierSection}}` prompt placeholder, and per-page records |
| `e26d24c9` | W5a | `LintProposalApplyService` — apply-on-approve through the `patchPage` CAS path with the full enforcement net |
| `8e1aff6a` | W5a | Progress note: the staged-proposal repair tier |
| `b58e1ad0`/`40a23489` | W5b | Proposal review value model + the Run Details review section (projected diffs, per-fix approve, Approve all, reject) |
| `68d7eeeb`/`945013cd` | W5b | Hosted review scenarios + progress note |

## The amended trust ladder (what ships)

The operator replaced "the eval gate authorizes repairs" with three tiers.
`LintAcceptanceGate.selection(for:)` computes the tier as a
`LintRolloutSelection`; checks run in order and the first rule wins:

1. **Tier 1 — silent repair** (`.repairAuthorized(approvalID:)`). A shipped
   approval row matches the configuration on the live pipeline, and the
   breaker is clean. The run repairs directly. One-click Undo, the circuit
   breaker, the patch budget, and CAS-guarded auto-revert on verification
   failure all stay active. Acceptance evidence buys **zero-ceremony
   authority** for that configuration — freedom from review friction. It is
   NOT the precondition for repair.
2. **Tier 2 — staged proposals** (`.stagedProposal(reason:)`). ANY
   unevaluated configuration still lints and fixes by default. The run stages
   exact hunks with `page propose-patch` (validated, budget-checked, at most
   one per page, never written). The human reviews projected diffs in Run
   Details and approves per fix or with Approve all. Approval applies the
   hunks through the same enforcement net: stale-head refusal, budget
   re-check, post-apply verification, auto-revert, breaker. A rejection
   records a `userRejected` breaker outcome.
3. **Tier 3 — report-only** (`.reportOnly(reason:)`). Degradation only: a
   missing, unreadable, undecodable, or structurally invalid manifest, a
   breaker-tripped configuration, and whole-wiki lint (always). Report-only
   classes (D02/D04/D05/D14/D18/D28) stay report-only at every tier.

Local state can only DEMOTE authority. The breaker (below) demotes a run to
report-only. Nothing the child process reads or says can raise a tier.

### The shipped approval manifest (schema 3)

`LintAcceptanceManifest` (Sources/WikiFSCore/Core/Lint/LintAcceptanceManifest.swift)
is a versioned bundle resource at
`Sources/WikiFSCore/Resources/LintAcceptance/manifest.json`. Schema 3 carries:

- a **pipeline block**: the lint-task prompt SHA-256, the detector revision,
  and the shipped canonical gate fixture digest (`LintAcceptanceManifest.Pipeline`);
- an **evidence block** (report hash, rubric reviewer, decision date, bail trials) —
  provenance, never matched at runtime;
- **approval rows** (id, provider, model, effort, evaluated revision, acceptance-key
  digest, authority).

"Enabled" is simply whether rows exist. Schema 3 removed `defaultReportOnly`:
an unevaluated configuration is tier 2 by construction, so a kill switch has
nothing to say. A manifest with rows must match the live build pipeline;
`LintAcceptanceGateTests` asserts the shipped pipeline equals
`LintAcceptanceManifest.Pipeline.live()` (prompt hash + detector revision +
fixture digest), so a build that changes any component cannot ship a stale
approval. Acceptance keys name evidence. They do not authorize by themselves.

### Minting an approval row (the eval's remaining role)

The evaluation harness keeps one job: producing the evidence a row carries.
A row removes review friction for exactly the configuration it evaluated.
The plan's original live-eval discipline still applies to minting a row: the
full gate suite (requirements §8.2) passes, and the operator reviews the
evidence, before the row ships.

`WikiLintEvalRunner manifest` (commit `359d07e2`) is the minting flow. It
computes the pipeline block from the live build, takes `--approval` rows and
the evidence flags, validates the candidate structurally, and prints it or
writes it under `tmp/` only. It never writes into the app bundle or the App
Group. The operator reviews the candidate and commits it as the shipped
resource.

### Enforcement machinery (file pointers)

- **Circuit breaker.** `LintRepairBreaker`
  (Sources/WikiFSEngine/LintRepairBreaker.swift). A rolling window of 10
  repair outcomes per configuration (provider/model/effort, keyed to the live
  pipeline digest, stored under `lint-breaker/` in the App Group). Trips at
  two or more `verificationFailure`, `userUndo`, or `userRejected` outcomes.
  Demote-only: a trip demotes tier 1 to report-only. State that is missing,
  unreadable, forged, or corrupt demotes. A pipeline change resets the
  window. Tier-2 keys need no approval row. Only the trusted host coordinator
  records or consults it; the sandboxed child is kernel-denied the App Group.
- **Patch budget.** `LintPatchBudget`
  (Sources/WikiFSCore/Core/Lint/LintPatchBudget.swift). 48 hunks and 65,536
  changed bytes per run at the ceiling, scaled by 3 hunks and 2,048 bytes per
  confirmed repairable finding (floors 8 hunks / 8,192 bytes). Enforced
  daemon-side at staging, and re-checked at apply time.
- **CAS auto-revert.** `revertPage(pageID:to:expectingHead:)` (commit
  `71aae72e`) puts the inspected head back when post-apply verification
  fails. `LintRevertOutcome` (Sources/WikiFSCore/Core/Lint/LintRepairAuthority.swift)
  records reverted / refused-head-diverged (FLAGGED for review) / not
  attempted / failed. The revert is a separate fact; the run stays a
  verification failure either way.
- **Proposal staging.** `page propose-patch` (Sources/WikiCtlCore, daemon wire
  in `DaemonCommandWire`) and the `DaemonLintStagedProposal` record. The
  daemon validates proposals with the same `PagePatchValidator` rules and
  budget discipline as `page patch`, requires the current snapshot receipt,
  and holds at most one proposal per page per run. Nothing is written; the
  staged record survives run teardown so review can happen after the run.
- **Apply service.** `LintProposalApplyService`
  (Sources/WikiFSEngine/LintProposalApplyService.swift): stale gate → budget
  re-check → the existing `patchPage` CAS path → W2a written-head
  verification → CAS auto-revert on failure → a trusted `--kind lint` audit
  entry for every outcome. A human rejection records `userRejected`.
- **Undo.** `LintUndoService` (Sources/WikiFSEngine/LintUndoService.swift)
  plus the Run Details Undo row: one `revertPage` CAS call per repaired page
  (a moved head is refused and reported, never clobbered), then one
  `recordUserUndo` for the run's configuration. `LintPageRecordFacts` recovers
  the authority tier, the approval id, and the heads from the durable record.
- **Review UI.** `QueueRunDetailsLintProposals`
  (Sources/WikiFS/Queue/QueueRunDetailsLintProposals.swift) renders the
  pending proposals with projected diffs and resolves them per fix or with
  Approve all through `LintProposalApplyService`.
- **Receipts and authority.** Run receipts carry the `approvalID` and the
  authority tier as `label=value` record fields.
  `LintRunMode` (directRepair / stagedProposal / reportOnly) replaced the
  two-bool repair-authorized encoding;
  `LintRepairAuthority` is the single authority value every surface reads.

## Key semantics (where to look)

- **Table alias-pipe semantics (sourced verdict).** A GFM table row like
  `| [[page:X|alias]] | text |` is MALFORMED per the GFM table extension:
  every unescaped `|` is a cell delimiter, and the extension requires
  pipes inside inline spans (links included) to be escaped. cmark-gfm and
  markdown-it scan rows block-first with no bracket awareness — excess
  cells are truncated, so the alias is severed from the link and the
  entry renders broken. Obsidian users report the same failure and the
  same workaround. Sources: github.github.com/gfm/#tables-extension-,
  github.com/github/cmark-gfm/blob/master/extensions/table.c,
  forum.obsidian.md/t/55052. Consequences:
  - D03 findings on such rows are TRUE positives (the production lint
    01M5QY0GWWR9S270DDGRJ7TQ0B was correct); the honest agent outcome is
    `unresolved` — the repair is not mechanical.
  - Correct authoring: escape the alias pipe (`[[page:X\|alias]]`) or use
    a pipe-free form. (Whether the wiki-link parser should accept `\|` as
    an alias separator is a follow-up reader/parser enhancement.)
  - A renderer MAY protect wiki spans before the table scanner to make
    unescaped aliases work — that is a deliberate GFM deviation, not a
    bug fix, and this plan does not make it.
- **Pure scanning.** `LintPagePreflight.scan` never touches the store; all
  store/package inputs are injected facts (`Sources/WikiFSCore/Core/Lint/`).
  Protected code is byte-masked to spaces so textual detectors share authored
  byte offsets with AST ranges.
- **Repairs.** `page patch` hunks are exact ranged edits with per-hunk defect
  classes and reasons; the store applies them atomically in exact-body mode
  (untouched bytes byte-identical). Report-only classes
  (D02/D04/D05/D14/D18/D28) cannot authorize hunks.
- **Accounting.** The agent fills a fixed-format run report (one line per
  inventory item, finding, and audit step). `LintCoverageValidator` rejects
  omitted/duplicated/unknown/wrong-head/contradictory outcomes; the harness
  never trusts counts alone.
- **Verification.** The daemon scans the WRITTEN immutable version after a
  committed patch (`DaemonLintVerificationRecord`); the coordinator re-scans
  the written bytes and runs `LintVerification.compare` with the change
  region observed from the store's own bytes. A moving current head is
  recorded as divergence, never merged.
- **Rollout gate.** Superseded by the amended trust ladder above.
  `LintAcceptanceGate` (WikiFSCore) + `LintCoordinatorGate` (WikiFSEngine)
  compute the selection; the acceptance key
  (provider/model/revision/effort + prompt bytes + detector revision + shipped
  fixture digests) names evidence for traceability. Selection is tier 1 only
  on a matching shipped row on the live pipeline with a clean breaker; tier 2
  is the default for every unevaluated or drifted configuration; tier 3 is
  degradation only.

## Amended acceptance wording (AC.13 / AC.14)

The rollout wording the older documents implied — evaluation authorizes
repair, no evidence means no repair — is replaced by the two statements
below. The requirements document keeps its original numbering; this is the
amended reading the implementation ships.

> **AC.13 (amended).** Acceptance evidence buys zero-ceremony authority for
> the configuration it evaluated: when a shipped approval row matches that
> configuration on the live pipeline, its repairs write directly, with
> one-click Undo, the breaker, the patch budget, and CAS auto-revert as the
> safety net — no review step. Evidence is NOT the precondition for repair.
> Any unevaluated configuration still lints and repairs by default at tier 2:
> its hunks stage for human review through `page propose-patch` and the Run
> Details approval flow. Report-only remains for degradation states only: an
> invalid or missing manifest, a breaker-tripped configuration, and
> whole-wiki lint.

> **AC.14 (amended).** A pipeline change (prompt hash, detector revision, or
> fixture digest) or a changed provider model revision demotes the affected
> approval row to tier 2 until the row is re-minted against the new pipeline.
> Re-minting follows the plan's original live-eval discipline: the full gate
> suite passes and the operator reviews the evidence before the row ships.

## Honest limits

- The live evaluation has not run yet (provider access, an operator-approved
  budget, and human rubric review are prerequisites). The shipped manifest
  therefore carries zero approval rows, and every configuration runs tier 2:
  lint still fixes pages, but a human approves each fix. Minting a row later
  does not change this document's enforcement story — it only removes review
  friction for that configuration.
- Inventory coverage proves accounting, not that a model truly read content;
  the seeded-defect oracle and live repetitions are separate evidence.
- Silent provider model replacements cannot be detected automatically; a
  suspected replacement demotes the affected row to tier 2 until
  re-evaluation.
- Evidence-audit classes D12/D13/D16 remain deferred (future operation);
  D19 off; D21 strategy-owned.
