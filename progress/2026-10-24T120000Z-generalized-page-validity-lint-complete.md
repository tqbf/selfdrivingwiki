---
timestamp: 2026-10-24T12:00:00Z
title: "Generalized page-validity lint: implementation complete, live gate blocked"
branch: feature/generalized-page-validity-lint
status: complete-pending-live-gate
---

# Generalized page-validity lint — implementation complete

Continuation of
`progress/2026-10-24T090000Z-generalized-page-validity-lint-phase4-5core.md`.
All deterministic phases (0–6 deterministic core, 7 documentation) are
implemented and committed on `feature/generalized-page-validity-lint`; the
full suite is green after every phase commit.

## Progress
- **`be711293` — Phase 6 core.** `WikiLintEval` target: fixture manifests
  (versioned tuning/held-out split, seeded defects, declared exact repairs,
  protected bytes, permitted unresolved, mechanical/judgment kinds), the
  canonical gate manifest (committed JSON), the diff oracle (reproduction
  from server-observed bytes; old-text honesty; protected-byte and
  full-body-replacement rejection; declaration match for mechanical
  fixtures), per-class scoring (report-only + bail rules), and
  `LintAcceptanceGate`. Shipped `LintGateFixtureManifest.json` (frozen
  digest `4024ba8a…`). `WikiLintEvalRunner` (inspect/replay/live-refusal)
  + `scripts/run-wiki-lint-eval.sh`. 9 harness tests.
- **`4d4d07b9` — rollout gate wired.** `LintAcceptanceGate` moved to
  WikiFSCore; `LintCoordinatorGate` computes the live key (provider/model/
  revision/effort + `LintPromptBodies.lintPageTaskSHA256` + detector
  revision + shipped fixture digest); `makeLintPagePlan` consults it before
  authorizing repairs and threads `repairAuthorized`/`gateReason` into the
  request and the prompt's `{{repairAuthorization}}` block. Unconfigured
  keys never match records → every current run selects REPORT-ONLY by
  construction.
- **`c700cbbc` (+ preceding doc commits) — Phase 7 docs.**
  `plans/generalized-page-validity-lint-implementation.md` (what landed,
  where, key semantics, honest limits) + `PLAN.md` index row;
  `plans/cli-domain-commands.md` gains "Page patch (the lint write path)"
  (hunk JSON, exact-body mode, receipt lifecycle);
  `plans/agent-sandbox-scoping.md` gains "Lint operation policies"
  (policy descriptor, receipt loop, rollout-gate selection).

## Verification

- `make prompts`, `make build`, bare `swift build` — clean.
- `make test`: **4722 tests / 487 suites passed** (~240s).
- `make lint`: 0 violations / 789 files; bare-try? hook clean.
- `WIKIFS_APP_TESTS=1` opt-in suites touched by this work pass
  (DaemonLintPolicyTests incl. receipt lifecycle, DaemonScopedSocketTests
  incl. the raw-frame receipt round trip, AgentSandboxProcessTests incl.
  AC.5 `lintCannotBypassEndpointPolicy`, AgentOperationRunnerTests,
  LintPromptContractTests, DaemonScopePolicyContractTests,
  DaemonScopedRunManagerTests, ScopedSandboxGateTests).
- New default-graph suites: `LintDetectorFixtureTests` (AC.4 class matrix),
  `LintOutcomeCoverageTests` (AC.10 coverage + verification),
  `WikiLintEvaluationHarnessTests` (AC.12/AC.14 oracle/scoring/gate).
- `WikiLintEvalRunner inspect` prints the canonical digest; the shipped
  resource matches it (`shippedFixtureDigestsMatchCanonicalManifests`).

## Blocked (operator prerequisites, per plan §6.14)

- **AC.13 live gate**: 20/20 bail trials at the lowest production tier,
  3× remaining groups, held-out + long-page coverage — requires operator-
  confirmed provider/model/tier, an approved total budget, and completed
  human rubric review. `run --live` reports the blocked prerequisites and
  makes NO provider calls. Rollout stays disabled (report-only) until the
  gate passes; `LintAcceptanceGateIntegrationTests` integration forms and
  the live trial plumbing land with the unblocked path.
- **Independent non-OpenAI implementation review**: the plan requires
  confirming the reviewer model with the operator (GLM 5.3 High selected
  for plan review) before running it; not yet executed.

## Known test-environment notes

- `timeoutTerminatesAndReapsProcessGroup` (50ms→500ms budget) and
  `IdentifierBoundaryTypecheckTests.negativeFixturesCompileAndMapBoundaries`
  are load-sensitive under full-suite parallelism; both pass standalone and
  the former was fixed (500ms preserves the timeout/reap intent).
