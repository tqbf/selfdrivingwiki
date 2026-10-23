---
timestamp: 2026-10-23T12:30:00Z
title: "Generalized page-validity lint: Phases 0-3 landed"
branch: feature/generalized-page-validity-lint
status: in-progress
---

# Generalized page-validity lint — Phases 0–3 landed

Implementation of `plans/generalized-page-validity-lint.md` (approved requirements)
per the approved execution plan (`sessions-v1/0ea115-green/plan-001.md`). Four of
seven phases are committed; the full suite passes after each commit.

## Progress

Commits on `feature/generalized-page-validity-lint` (base `5aeadc68`):

- **`ca7de2f2` — Phase 0.** All lint references removed from
  `prompts/system-prompt-default.md` (D1); `lint-page-task.md` is self-contained;
  `lint-task.md` states its own report-only policy. `WikiStore.readPageCoherent(id:)`
  (new `PageCoherentRead`) reads identity+title+body+head+source-inputs in ONE read
  transaction; `WikiStoreModel.preflightLint` now fixes brackets under CAS carrying
  the captured head + unchanged provenance, recomposes ONCE on conflict, stops hard
  after a second, re-reads the persisted body before claiming success, never
  overwrites a dirty draft, and reports honest success (`LintPreflight` gained
  `inspectedHead/writtenHead/repairLocations/fixFailure`; `WikiLinkFixer.
  applyFixesWithRanges` supplies locations).
- **`117c9be4` — Phase 1.** `WikiFSMarkdown` gains the shared parser foundation:
  `ParsedMarkdownDocument` (reader's parse config + `MarkdownSourceLineTable`
  extracted from the app), `MarkdownCodeProtection` (AST-derived), `MarkdownFenceFacts`
  (marker/length/info/container/opening/closing from source slices; legal EOF fences
  flagged as such), `MarkdownFootnoteAnalysis` (occurrence-preserving; duplicates
  keep ranges). `WikiFootnoteMarkdown.rendered` runs on it with byte-identical
  output; `WikiLinkParser.syntaxNodes(in:protectedRanges:)` accepts external
  protection. WikiFSCore gains the typed contract: `LintDefectClass` (D01–D28 +
  repairPolicy), `LintScanSection` (REQ-23 order), `LintScanStatus`,
  `LintPageSnapshot`, `LintFinding` (+ candidate repairs), `LintInventoryItem`,
  `LintFindingOutcome`, `LintRepairRecord`, `LintPreflightReport` (named limits),
  and `LintPagePreflight.scan` — pure scanner with inventory, D25 (whole-body wrap,
  separate open/close deletion candidates), D06 (attempted expressions), D07/D08/D10
  (identity + unique-match canonicalizing candidates), D22 (footnote integrity).
  `LintResolutionFacts.load(from:)` reads identity facts from any store.
- **`b5e6c036` — Phase 2.** `ManagedRunPolicy` (ordinaryManaged /
  lintSelectedPageRepair(pageID) / lintSelectedPageReportOnly(pageID) /
  lintWholeWikiReportOnly) threads immutably through `AgentScopedRunLeaseManaging`,
  `DaemonScopedRunLeaseManager`, the broker, registry lease, and every grant. Lint
  leases carry READS ONLY (no broad wikiEdit fallback). The scoped guard substitutes
  a lint allowlist: reads pass, `log append` requires kind `lint` (minimally
  decoded, generic denial otherwise), everything else fails closed.
  `DaemonLintRunState` is the trusted per-run CAS budget: receipts tied to
  head+fingerprint, invalidated by commits/new reads, hard two-conflict close.
- **`3fdc97be` — Phase 3.** `PagePatchHunk/PagePatch/PagePatchValidator` (exact
  ranged repair; typed rejections before any write; report-only classes cannot
  authorize hunks); `WikiStore.patchPage` atomic in `GRDBWikiStore` — CAS, exact-body
  mode (NO canonicalization/cosmetic fixing; untouched bytes byte-identical),
  added-citation integrity (unique resolution; quote checked against the PINNED
  version's text, whitespace-normalized + case-sensitive), provenance union, links
  parsed from committed bytes, one event only on changed commit.
  `wikictl page patch --id --expect-head (--hunk <json> --defect <class>)… |
  --hunk-file` with strict alternation parsing; daemon wire (`Page.patch`,
  `DaemonPagePatchRequest`) executes through the same `PageCommand` layer with no
  linter/validator. The lint policy gate pins patches to the run's selected page
  (repair policy only). `lint-page-task.md` flipped to the patch-only contract;
  `LintPromptContractTests.finalTaskHasNoFullBodyWritePath` replaces the interim test.

## Remaining (Phases 4–7)

- **Phase 4 — detector coverage.** Extend `LintPagePreflight` with the remaining
  classes per the plan: D01 (fence boundary facts exist — add suspicious-closure
  cases), D03 (malformed tables that parse as paragraphs), D02/D04/D05/D14
  (report-only candidates), D09 (quote/anchor/pin availability vs the source
  store), D11 (raw-URL exact origin-URL matches → candidate repairs; needs origin
  URLs in the resolution facts), D15 (merge markers + ≥80-char duplicate blocks),
  D17/D26 (encoding/escaping), D18 (active content, report-only), D20 (reference
  labels/local media), D23 (truncation), D24 (meta-text leakage), D27 (history
  regression vs previous head, 30% shrinkage threshold), D28 (rich-fence
  re-validation with the async validated/invalid/unclaimed/suppressed/unavailable
  API in `FenceSyntaxValidator`). The section skeleton and statuses are in place
  (integrityAndHistory is currently `notChecked` — flip it as detectors land).
- **Phase 5 — per-page execution + verification.** Carry `LintPageSnapshot`/typed
  page identity through `OperationRequest.lintPage`/`WikiOperation.lintPage` (today
  they join titles); one shared coordinator in `WikiFSEngine` used by
  `AgentOperationRunner`, `AppQueueIngestionProvider`, `DaemonQueueIngestionProvider`
  (each requested page = its own run/policy/artifacts/outcome); wire
  `DaemonLintRunState` receipts into `page get --json` responses and patch handling
  (mint on fresh read of the selected page, validate on patch, invalidate on
  commit, record conflicts); app-side post-write re-scan of the WRITTEN head;
  REQ-29 ten-check report; `--kind lint` log contract; queue reporting + Run
  Details surfaces. Add the endpoint/socket bypass tests for lint children
  (AC.5 `AgentSandboxProcessTests.lintCannotBypassEndpointPolicy`).
- **Phase 6 — evaluation + gate.** `WikiLintEval`/`WikiLintEvalRunner` targets +
  `scripts/run-wiki-lint-eval.sh`, fixture manifests (§8.3 groups, held-out split),
  diff oracle, per-class scoring, `run --live --gate`, acceptance records under the
  App Group `lint-acceptance/<key>.json`, shipped `LintGateFixtureManifest.json`
  resource, unaccepted→report-only selection, harness-only evaluation admission.
  LIVE GATE BLOCKED on provider access + operator budget + human rubric (do not
  claim rollout readiness).
- **Phase 7 — docs/review/delivery.** Implementation plan doc
  (`plans/generalized-page-validity-lint-implementation.md`) + `PLAN.md` link;
  document the CLI patch JSON in `plans/cli-domain-commands.md` and the policy in
  `plans/agent-sandbox-scoping.md`; more progress notes; independent
  non-OpenAI implementation review (operator selected GLM 5.3 High for plan review);
  conventional commits per phase (already the pattern).

## Verification

- `make build` and bare `swift build` pass; `make lint` clean (0 violations).
- Full default suite after each phase commit: **4698 tests / 485 suites passed**
  (`swift test`, ~4 min, in-memory fixtures).
- Opt-in app suites touched by this work pass under `WIKIFS_APP_TESTS=1`:
  `DaemonLintPolicyTests` (7 tests: four-policy operation matrix, log-kind
  conditioning over raw frames, patch selected-page identity, policy immutability,
  CAS receipt/conflict budget), `DaemonScopePolicyContractTests`,
  `DaemonScopedRunManagerTests`, `DaemonScopedSocketTests`, `ScopedSandboxGateTests`,
  `AgentSandboxProcessTests` (17 tests).
- New regression suites: `LintSnapshotTests`, `LintBracketRepairTests` (real
  two-connection WAL races), `LintPromptContractTests`, `LintMarkdownAnalysisTests`,
  `LintFootnoteAnalysisTests`, `LintPreflightTests`, `PagePatchCommandTests`
  (parser/validator/atomicity/integrity).
- Known flake avoided in tests: ULIDs are NOT monotonic within one millisecond —
  `PagePatchTests` derives pin ordinals from `processedMarkdownHistory` order
  rather than assuming write order.
- Not yet run: `WIKIFS_APP_TESTS=1 swift test --filter 'PreparedMarkdownDocument|
  TypedMarkdownHTMLRenderer|MarkdownHTMLRenderer'` focused reader suites (reader
  refactor was validated by `WikiFootnoteMarkdownTests` + full suite); Phase 5+ will
  exercise them.
