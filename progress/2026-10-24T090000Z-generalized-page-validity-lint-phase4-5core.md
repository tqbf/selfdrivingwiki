---
timestamp: 2026-10-24T09:00:00Z
title: "Generalized page-validity lint: Phase 4 landed, Phase 5 core contract landed"
branch: feature/generalized-page-validity-lint
status: in-progress
---

# Generalized page-validity lint — Phase 4 + Phase 5 core contract

Continuation of `progress/2026-10-23T123000Z-generalized-page-validity-lint-phases-0-3.md`.
Phases 0–3 plus the two commits below are on
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

1. **Typed operation cases.** `OperationRequest.lintPage(pageTitle:brokenLinks:
   stateMarkdown:)` (Sources/WikiFSEngine/OperationRequest.swift:48) and
   `WikiOperation.lintPage` (Sources/WikiFSCore/Core/WikiOperation.swift:65)
   carry joined titles; change to carry `LintPageSnapshot` (pageID+title+head)
   plus the staged pre-flight artifact; `lintPagePrompt` consumes the
   snapshot identity + artifact path + `LintAuditStep` instructions +
   `LintRunReportText.render` skeleton. Runners at
   `AgentOperationRunner.runLintPages` (:514), `AppQueueIngestionProvider.
   runLintPages` (:416), `DaemonQueueIngestionProvider.runLintPages` (:269)
   still title-join.
2. **Coordinator.** One shared selected-page coordinator (WikiFSEngine): per
   page sequentially — coherent read → facts load (off-main via WikiReadService)
   → `LintPagePreflight.scan` → own agent run → parse report → coverage
   validate → patch (existing `page patch` path) → re-scan WRITTEN head →
   `LintVerification` → `--kind lint` log append (detect committed) → outcome
   map (missing pages blocked/skipped with reasons; cancellation stops future
   pages; no retry of completed pages).
3. **Daemon receipts** into `page get --json` + patch handling
   (`DaemonLintRunState` already exists from Phase 2).
4. **Queue reporting** (`QueueReportMutation.targetUpserts`) with observed
   findings/verification; replace `.notReported` only with real records; Run
   Details rows for repaired/valid-as-written/unresolved/outside-scope/blocked.
5. **AC.5 test** `AgentSandboxProcessTests.lintCannotBypassEndpointPolicy`.

## Verification

- `make build`, `make lint` (0 violations/781 files) clean; pre-commit
  bare-try? gate clean.
- Full suite after Phase 4 commit: **4710 tests / 486 suites passed**
  (`make test`, ~240s). Focused suites green after `ddfe43f6` (12 + 39).
- Gotchas that cost time: swift-markdown `Image.source` (not `.destination`);
  `Table.Body.rows`; `firstMatch` IS optional; `firstIndex(where:)` needs its
  label; converted AST ranges start at content (use overlap, not containment);
  tuples break synthesized `Equatable`; report tokens are kebab-case while
  occurrence IDs keep camelCase kind rawValues (`sourceCitation-1`).
