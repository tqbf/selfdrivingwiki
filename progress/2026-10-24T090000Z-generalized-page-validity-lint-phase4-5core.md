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

## Phase 5 COMPLETE (`01c2127f`)

All §5.1–§5.15 landed: typed identity, shared coordinator, sequential
per-page runs, coordinator dispatch tests, REQ-29 ten-check prompt, fixed
run-report format + strict parser, coverage validation, daemon receipts
(mint/validate/invalidate/conflict-budget) through the scoped socket, daemon
written-version verification records (read by the queue host via the shared
`queueHostLintRunState`), host `--kind lint` audit log (agent-log
detection), REQ-54 full compare with store-observed change regions, queue
reporting with observed facts, Run Details via the existing `.available`
summary rows, whole-wiki report-only (verified), and the AC.5 live sandbox
test.

## Phase 6 remaining (after `be711293` core)

**LANDED `be711293`**: WikiLintEval target (manifest model + canonical gate
manifest JSON + diff oracle + scoring + acceptance gate), shipped
`LintGateFixtureManifest.json` (frozen digest `4024ba8a…`) + loader,
WikiLintEvalRunner (inspect/replay/live-refusal), scripts/run-wiki-lint-eval.sh,
9 harness tests (oracle, scoring controls, held-out frozen, gate
invalidation, admission scoping, shipped-digest match).

Still open in Phase 6:
1. ~~Coordinator gate wiring~~ **LANDED `4d4d07b9`** — LintAcceptanceGate moved
   to WikiFSCore; LintCoordinatorGate (WikiFSEngine) computes the live key
   (provider/model/revision/effort + LintPromptBodies.lintPageTaskSHA256 +
   detector revision + shipped fixture digest) and consults production;
   makeLintPagePlan threads repairAuthorized/gateReason into the request
   and the prompt's {{repairAuthorization}} block — unaccepted runs are
   REPORT-ONLY by construction (unconfigured keys never match records).
   Remaining integration test: LintAcceptanceGateIntegrationTests forms.
2. Live trial plumbing … (BLOCKED as below)
3. Harness-only evaluation admission … (BLOCKED with the live path)

## Independent review (Opus 5.5) — triage

`plans/independent-review-opus55.md` (verbatim, commit `e39d2dfc`). Verdict:
building blocks sound; enforcement layers not connected to production; two
critical defects in the deterministic core. Fix-or-rebut status:

- **C2 (critical) — FIXED `6f314c9a`.** Masked-regex offset drift (UTF-16
  conversion against the source) → wrong ranges, EOF `NSRangeException`.
  All sites convert via `authoredMatch` (masked text for ranges, source
  for evidence); regression tests with CJK-in-fence and drift-past-EOF.
- **C3 (critical) — FIXED `6f314c9a`.** Composer order-dependence
  (insertion+replacement at one offset committed undeclared bytes).
  Shared-start hunks reject; composition is concatenation; the oracle
  mirrors the same composer.
- **M2 (major) — FIXED `6f314c9a`.** Untouched skeleton now a PARSE error
  (`pending` is never a valid outcome token); `name|reason` splitting
  fixed for multi-word reasons; validator requires reasons on
  items/findings and a filled verification line.
- **m4 (minor) — addressed en passant** (documented dedup semantics).
- **C1 (critical) + M1 (major) — FIXED `8d34ca5c`.** `AgentLauncher`
  derives the managed-run policy from the request alone (repair-authorized
  lintPage → repair lease, unauthorized → report-only lease, `.lint` →
  whole-wiki report-only, others ordinary; pure mapping, unit-tested); a
  lint launch without a configured scoped-run manager is REFUSED (no
  unscoped fallback for lint). Both issue sites pass the policy; the
  rollout-gate's repairAuthorized decision now reaches the LEASE, not just
  the prompt. Post-run accounting factored into
  `AgentOperationRunner.accountForLintRun` over the WikiStore protocol and
  called per page by BOTH queue providers — coverage-rejected /
  verification-failed / agent-log-missing pages are `.failed` in the
  observed outcomes and fail the item, never "run completed".
- **M3 (major) — FIXED `015646ec`.** Written-head verification scan loads
  the same facts as the pre-run scan; D28's async fence facts stay
  pre-scan-only (documented — no candidate repairs, cannot flip verdicts).
- **M4 (major) — FIXED `4dad557f`.** Receipt validates head == expectHead;
  casConflict invalidates the receipt too.
- **M5 (major) — FIXED `4dad557f`.** Added citation with an unresolved
  `@vN` pin is a typed rejection, with or without a fragment.
- **M6 (major) + m5 (minor) — FIXED `015646ec`.** Broker revoke calls
  `forgetLintState` — receipts, counters, and records die with the run.
- **M7 (major) — FIXED `015646ec`.** Task prompt REQUIRES the agent's log
  title to start with the page title; the host matches entries by page,
  window widened to 200.
- **M8 (major) — FIXED `7fec64cf`.** Unresolved gate components hard-fail
  to report-only BEFORE record lookup (a constant key is publicly
  computable); child-writable lint-acceptance/ is outside the seatbelt
  boundary by construction.
- **M9 (major) — FIXED `7fec64cf`.** Per-defect scoring (duplicate-class
  trap gone), declaration consumption in the oracle, merged-coverage
  rewrite detection, hidden bail fixtures added to held-out (manifest
  revision 2, digest regenerated — prior evidence invalid).
- **m1 (minor) — accepted, queued** with the launcher wiring follow-up.
- **m2 (minor) — FIXED `4dad557f`.**
- **m3/m4 (minors) — accepted:** escaped-pipe cell counting and CR-only
  line tables queued; m4's dedup semantics documented.
- **m6 (minor) — REBUTTED in part:** `preflightLint` remains the Phase 0
  interim CAS path pinned by `LintBracketRepairTests`/`LintSnapshotTests`;
  its removal is the scoped-run launcher's decision, not this plan's.
- **m7 (minor) — FIXED `8d34ca5c`.** Per-page outcomes now fail the item.
- **m8 (minor) — accepted:** digest-over-decoded-struct noted in the
  manifest doc; fails safe.
- **Doc overclaims — FIXED `df358a97`/`c700cbbc` + this note:** both docs
  now state that the gate selects report-only for every current
  configuration and that production minting landed with `8d34ca5c`.

## Phase 6/7 remaining (authoritative)

1. Phase 6: `WikiLintEval`/`WikiLintEvalRunner` targets +
   `scripts/run-wiki-lint-eval.sh`; fixture manifests (§8.3 groups,
   held-out split, frozen digests); diff oracle from observed bytes;
   per-class scoring; `inspect`/replay/`run --live --gate`; harness-only
   evaluation admission; acceptance records (`lint-acceptance/<key>.json`),
   shipped `LintGateFixtureManifest.json`, unaccepted→report-only,
   `LintAcceptanceGate*` tests. LIVE GATE BLOCKED on provider access +
   operator budget + human rubric.
2. Phase 7: implementation doc + PLAN.md link, CLI patch JSON +
   sandbox-scoping docs, progress notes, independent non-OpenAI review
   (GLM 5.3 High), conventional commits.

## Superseded remaining list (Phase 5 wiring — historical)

Landed since this note was first written: **`ddfe43f6`** (audit checklist +
run-report contract + coverage/verification gates), **`5bd10c7e`** (typed
identity + staged artifacts + per-page sequential dispatch through all three
entrypoints; observed per-page outcomes replace `.notReported` only when the
host supplies them; title-join tests replaced with coordinator dispatch
tests), and **`17105b0b`** (daemon snapshot receipts WIRED: a repair-policy
run's `page get --id <selected> --json` mints a receipt into the JSON reply;
`page patch --lint-receipt` must present the CURRENT token — stale/absent/
closed deny with the generic scope message; commit invalidates; a typed
casConflict burns one recomposition and the second closes the run;
lint-page-task.md + CLIReference teach `--lint-receipt`), and **`e824e9a3`** (AC.5 LANDED:
`AgentSandboxProcessTests.lintCannotBypassEndpointPolicy` drives the real
sandboxed CLI through the real scoped endpoint — mint on the selected JSON
read, generic denials for missing/forged receipts, non-selected pages and
non-lint log kinds, the receipted patch commits exactly, the replayed
receipt then denies, the non-selected page stays byte-identical; plus
receipt-budget errors now convert to the generic scope denial and minting
handles the DaemonCommandOutcome envelope).

1. ~~`--kind lint` host log (§5.12)~~ **LANDED `6280f47c`** — the host appends its audit record per page (written head, coverage verdict, unresolved ids, agent-log detection; missing agent log or failed append = run failure), app-side and daemon-side.
2. ~~REQ-54 full compare~~ **LANDED `a492b0b5`** — the daemon scans the WRITTEN immutable version right after a committed patch and publishes `DaemonLintVerificationRecord` into the trusted per-run state; the coordinator re-scans the written bytes and runs the FULL `LintVerification.compare` with the change region observed from the store's own bytes (`observedChangeRanges` prefix/suffix trim) and the coverage-validated claims; a failed compare fails the page outcome, divergence is recorded. Remaining: the daemon-queue host reading its dispatcher's published record into its per-page summary (small wiring).
3. **Run Details surfaces (§5.14)** — the completion summary already carries observed per-page facts; verify the existing Run Details rows render them (they render `resultSummary`), and that `.available` availability renders. Likely a small/no-op change with a UI test.
4. **End-to-end socket receipt test** in DaemonScopedSocketTests (unit semantics pinned in DaemonLintPolicyTests; AC.5 covers the live path already — this is the raw-frame form).
5. **Whole-wiki prompt alignment (§5.15)** — VERIFIED done: `lint-task.md` is
   explicitly REPORT-ONLY (no repair fan-out), pinned by
   `LintPromptContractTests.wholeWikiIsReportOnly`.
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
