---
timestamp: 2026-10-05T010500Z
title: Batch-aware ingest turn ceiling
branch: feature/batch-aware-ingest-ceiling
status: complete
---

# Batch-aware ingest turn ceiling

## Progress

Job 01M44Q63RGKAX84Q0N2YE7YMMS (61 sources, 2026-10-04) hit the queued
ingestion turn ceiling at 603s and failed. The 600s ceiling from issue #609
bounds a stall, but a large batch legitimately needs more than one flat
10-minute turn of work.

The operator asked whether to warn users away from large batches or raise
the ceiling. Warning adds friction and does not fix the unattended pipeline,
and removing the ceiling removes the only stall backstop (the idle path is
gone by design). The fix scales the ceiling with the batch:

- `TurnLivenessPolicy.queuedCeiling(workUnits:)` is the pure decision:
  600s flat up to 10 work units, then +20s per additional unit, capped at
  3600s. A 61-source batch resolves to 1620s. The constants live on the
  policy type with their rationale.
- `TurnLivenessPolicy.ceiling(for:workUnits:)` threads the batch through
  the existing per-kind decision point. `nil` keeps the flat ceiling and
  `.chat` ignores the batch, so chat and lint behavior is unchanged.
- `AgentProviderRuntime.prepare` and the `AgentProviderServices` protocol
  carry a `queuedWorkUnits` parameter to `makeSnapshot`, where the
  `AgentOperationPolicy` turn ceiling is resolved.
- `AgentLauncher.run` passes the staged source count for `.ingest`
  requests. The single-shot path and the planner/executor path share that
  preparation, so both get the scaled ceiling.

Small batches (the #609 scenario) keep the exact 600s stall bound.

## Verification

- `make build` passed.
- `make test` passed (default graph, 0 failed runs).
- `WIKIFS_APP_TESTS=1 swift test --filter TurnLivenessPolicyTests` passed:
  15 tests, including 4 new tests for the flat region, the per-unit scaling,
  the cap, and the per-kind threading.
- `WIKIFS_APP_TESTS=1 swift test --filter AgentLauncherCeilingWiring`
  passed (existing #609 wiring contract).
