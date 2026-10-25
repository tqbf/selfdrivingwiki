---
timestamp: 2026-10-25T21:00:00Z
title: W3 live gate driver — implemented; live run blocked on the named provider prerequisite
branch: feature/generalized-page-validity-lint
status: driver-complete-live-blocked
---

# W3 — the live gate driver (`WikiLintEvalRunner run --live --gate`)

Continuation of
`progress/2026-10-24T120000Z-generalized-page-validity-lint-complete.md`
(the "AC.13 live gate" blocked item). The driver is implemented, gated,
and committed; the authorized live evaluation did NOT run because the
authorized configuration does not exist in the operator's provider
configuration. The gate named the prerequisite and made NO provider
calls, exactly as designed.

## Progress
- **`55cdd478` — the live gate driver.**
  - `WikiFSEngine`: `AgentOperationRunner.makeEvaluationLintPagePlan` /
    `runOneEvaluationLintPage` — the harness-only evaluation admission
    dispatch. Repair capability requires BOTH
    `LintAcceptanceGate.evaluationAdmission` (only the disposable wiki ids
    the driver just created) AND exact configuration identity with the
    declared evaluated components; the circuit breaker still demotes. A
    breaker-clean grant relabels `.shippedApproval` onto
    `.evaluationAdmission`. `AgentLauncher.oneShotThinkingOverride` pins
    the evaluated effort tier on one-shot runs.
  - `WikiLintEval`: `LintLiveGateDriver` + `LintLiveGateConfiguration`,
    `LintLiveGateResolution` (read-only provider-config resolution; a
    missing provider/model/effort tier is a NAMED prerequisite, never a
    fallback), `LintLiveGateBudget` (8-hour wall-clock ceiling, capped
    exponential rate-limit backoff), `LintLiveGateSuiteComposer` (20
    independent bail trials + 3 runs of every remaining fixture group;
    clean-page runs are AC-06 idempotence pairs), `LintLiveTrialRecord` +
    `LintLiveGateReport` (capture per plan §6.11; declaration-anchored
    hunk reconstruction with a store-observed-region fallback; FAILED
    trials persist in totals; human-rubric sections stay PENDING
    OPERATOR).
  - `wikid`: `LintEvalDaemonSubstrate` + the `lint-eval-driver` host mode
    — the only process that can boot the eval daemon substrate (registry +
    dispatcher + socket server + broker + scoped-run lease manager) over
    the DEDICATED eval App Group container. The host owns the reserved
    constructions and injects them via `LintLiveGateFactories`
    (`scripts/check-cordis-boundaries` allowlists the host file with
    rationale).
  - `WikiLintEvalRunner run --live --gate` spawns the host binary, streams
    progress from the report file, and exits with the AC.13 verdict (0
    PASSED / 1 FAILED / 2 usage / 3 blocked prerequisite). `--manifest`
    must match this build's canonical digest.
  - 11 deterministic driver tests joined `WikiLintEvalTests`; live runs
    are not unit-tested.
- **`1382d373` — spawn fixes.** The host-mode word moved onto a lazily
  initialized static (a top-level `let` declared after the dispatch
  switch read as "" — the child booted as the ordinary XPC service);
  `--live`/`--gate` parse as boolean flags; the child inherits
  `WIKI_APP_GROUP_ID` = the eval container from process start;
  `LINT_EVAL_HOST_BIN` overrides the host binary for testing.

## Verification
- `make build` clean (app built + signed).
- `make test` full suite green (4720+ tests incl. the Cordis boundary
  suites after the factory injection).
- Bare `swift build` clean; `make lint` clean.
- `swift run WikiLintEvalRunner inspect --manifest
  Sources/WikiLintEval/Fixtures/canonical-gate-manifest.json` prints the
  canonical digest `25abd05ab1a65537e471fc47afa22fad62f1b53cbe381d39353d4140670eeda8`.
- Replay positive control (canned correct run): 0 failing fixtures, exit
  0; negative control (one missed bail seed): 1 failing fixture —
  `tmp/w3-replay-good.json` / `tmp/w3-replay-bad.json`.
- Live gate execution (`run --live --gate`, default `--provider zai
  --model "GLM 5.3 Flash"`): **BLOCKED, exit 3, no provider calls** —
  "named prerequisite: no ENABLED provider 'zai' in the operator's
  provider configuration (enabled: codex-acp, gemini, pi-acp)". The
  operator's lint stage resolves to codex-acp `gpt-6-luna[high]`; no GLM
  5.3 Flash model exists in either container's `agent-providers.json`
  (the nearest route is pi-acp → the pi agent's fireworks catalog,
  `accounts/fireworks/routers/glm-flash-latest`, "GLM 5.3 Flash (Latest)"
  — a DIFFERENT serving provider than the authorized "zai"). Log:
  `tmp/w3-live-run.out`.

## Blocked (operator decision needed, per plan §6.14)
- The AC.13 live gate needs one of:
  1. the operator adds/enables a `zai` provider serving GLM 5.3 Flash in
     the app's Settings → Providers (the driver then runs as-is), or
  2. the operator re-authorizes the actual reachable route with
     `--provider pi-acp --model "GLM 5.3 Flash"` (Fireworks router — a
     different provider identity in the acceptance key), or
  3. the operator names another configuration entirely.
- Human rubric review of the eventual gate report stays a separate
  operator prerequisite; the report's rubric sections are PENDING
  OPERATOR by construction.
