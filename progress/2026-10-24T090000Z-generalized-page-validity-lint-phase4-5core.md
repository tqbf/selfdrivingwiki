---
timestamp: 2026-10-24T09:00:00Z
title: "Generalized page-validity lint: Phase 4 landed, Phase 5 core + dispatch landed"
branch: feature/generalized-page-validity-lint
status: in-progress
---

# Generalized page-validity lint — Phase 4 + Phase 5 core contract

Continuation of `progress/2026-10-23T123000Z-generalized-page-validity-lint-phases-0-3.md`.
Phases 0–3 plus the commits below are on
`feature/generalized-page-validity-lint`; full suite green after each.

## Progress

- **`de0e7437` — Phase 4 (detector coverage), COMPLETE.**
  `LintDetectors.swift` implements every in-scope class: D01 suspicious fence
  closures, D02 delimiter parity, D03 unparsed table shapes + row mismatches
  counted from SOURCE lines (cmark truncates over-long rows to the header
  width — the AST cannot see them), D04 list-indent jumps + accidental
  indented code blocks (match by line OVERLAP: converted block ranges start at
  the content, not the indent), D05 heading jumps/duplicates, D14 reviewed
  placeholders, D15 conflict markers + 80-char duplicate blocks, D17 encoding,
  D18 active content, D20 reference labels + scheme-less media destinations,
  D23 truncation candidates, D24 meta-text phrases/tool markers, D26 double
  entities/bidi/escaped wiki syntax. Protected code is byte-masked to spaces
  (`byteMasked`) so regex/scalar scans share authored byte offsets.
  Injected facts keep the scan pure: `LintCitationFacts` (D09, pin chain via
  `sourceDerivedChains`), `LintOriginURLFacts` (D11 — enumerate per-source
  origin identities via `sourceEditHistory`; the store's
  `sourceMatchingURLIdentity` silently prefers the newest row, unusable for
  ambiguity), `LintHistoryFacts` (D27 actual parent via `pageVersionHistory` +
  `pageVersionBody`), `LintFenceValidationFacts` (D28). New async
  `detailedFenceValidation` on `FenceSyntaxValidationService` with
  validated/invalid/unclaimed/suppressed/unavailable outcomes (save-warning
  API unchanged). Sections apply the per-section finding limit with honest
  truncation; integrityAndHistory is real (blocked on history read failure);
  detector revision → `lint-preflight-v2`. `LintDetectorFixtureTests.classMatrix`
  = AC.4.
- **`ddfe43f6` — Phase 5 core contract.** `LintAuditStep` (ten REQ-29 checks,
  kebab `reportToken`s), `LintRunReportText`/`LintRunReportParser` (fixed
  report format: `lint-run-report v1`, page/head/fingerprint, six inventory
  counts, `check <token> <outcome>|<reason>`, `item|finding <occurrenceID> …`,
  `verification <head|none> <verdict>`; unknown lines are parse errors;
  DUPLICATE check/item/finding lines parse and the validator rejects them),
  `LintCoverageValidator` (REQ-31/32: missing/duplicate/unknown/wrong-head/
  wrong-page/contradictory rejected; every step exactly once; no `repaired`
  on steps or report-only classes; inventory counts must match),
  `LintVerification.compare(before:written:appliedHunks:claimedRepairFindingIDs:
  writtenHead:currentHead:requiredChecksAvailable:)` (claimed-repair-persists,
  new-finding, unattributed-disappearance, unavailable-check → failed;
  moving current head → `verifiedWrittenHeadDiverged`).
  12 tests in `LintOutcomeCoverageTests`.

## Remaining (Phase 5 wiring, then 6–7)

Landed since this note was first written: **`ddfe43f6`** (audit checklist +
run-report contract + coverage/verification gates), **`5bd10c7e`** (typed
identity + staged artifacts + per-page sequential dispatch through all three
entrypoints; observed per-page outcomes replace `.notReported` only when the
host supplies them; title-join tests replaced with coordinator dispatch
tests), and **`28f00312`** (daemon snapshot receipts WIRED: a repair-policy
run's `page get --id <selected> --json` mints a receipt into the JSON reply;
`page patch --lint-receipt` must present the CURRENT token — stale/absent/
closed deny with the generic scope message; commit invalidates; a typed
casConflict burns one recomposition and the second closes the run;
lint-page-task.md + CLIReference teach `--lint-receipt`).

1. **`--kind lint` host log (§5.12).** After each completed audit the host
   appends the required log entry (inspected/written heads, server-observed
   hunk classes, named audit outcomes, retained candidates, unresolved
   findings, CAS/readback/validation/log outcomes), detects whether the
   agent's own append committed, and records failures in artifacts + queue
   state — never reporting complete success on a log failure.
2. **REQ-54 app-side re-scan via `LintVerification.compare`** is wired into
   the coverage path for claims; the FULL compare (before/written hunks from
   server-observed receipts) lands with the daemon verification record.
   Exposed defects must join the same run's worklist (§4.10).
3. **Run Details surfaces (§5.14).** Render repaired / valid-as-written /
   unresolved / outside-scope / blocked outcomes in the existing Activity/Run
   Details rows (the completion summary already carries observed facts).
4. **AC.5 test** `AgentSandboxProcessTests.lintCannotBypassEndpointPolicy`
   (raw frames, omitted credentials, alternate endpoint, direct DB writes),
   plus an end-to-end socket test of the receipt loop in
   DaemonScopedSocketTests (the unit-level semantics are pinned in
   DaemonLintPolicyTests.receiptLifecycleMintValidateInvalidateClose).
5. **Whole-wiki prompt alignment (§5.15)** — report-only, never fanned into
   repair runs.
7. **Phase 6** (`WikiLintEval`/`WikiLintEvalRunner` targets,
   `scripts/run-wiki-lint-eval.sh`, fixture manifests §8.3 with held-out
   split, diff oracle from server-observed bytes, per-class scoring,
   `run --live --gate`, acceptance records under the App Group
   `lint-acceptance/<key>.json`, shipped `LintGateFixtureManifest.json`,
   unaccepted→report-only selection, harness-only evaluation admission) —
   LIVE GATE BLOCKED on provider access + operator budget + human rubric.
8. **Phase 7** — `plans/generalized-page-validity-lint-implementation.md` +
   `PLAN.md` link; CLI patch JSON in `plans/cli-domain-commands.md`; policy in
   `plans/agent-sandbox-scoping.md`; independent non-OpenAI implementation
   review (operator selected GLM 5.3 High); conventional commits per phase.

## Verification

- `make build`, `make lint` (0 violations/781 files) clean; pre-commit
  bare-try? gate clean.
- Full suite after `5bd10c7e`: **4722 tests / 487 suites passed**
  (`make test`, ~240s). WIKIFS_APP_TESTS=1 suites touched by this work pass.
- Gotchas that cost time: swift-markdown `Image.source` (not `.destination`);
  `Table.Body.rows`; `firstMatch` IS optional; `firstIndex(where:)` needs its
  label; converted AST ranges start at content (use overlap, not containment);
  tuples break synthesized `Equatable`; report tokens are kebab-case while
  occurrence IDs keep camelCase kind rawValues (`sourceCitation-1`);
  `silent_try_optional` rejects bare `try?` in Sources (do/catch + DebugLog);
  `AgentOperationRunner` is MainActor — returned plans must be `Sendable`;
  the daemon queue path has a plain `WikiStore` (no model), so the shared plan
  builder takes `WikiStore` + `stateMarkdown` directly.
