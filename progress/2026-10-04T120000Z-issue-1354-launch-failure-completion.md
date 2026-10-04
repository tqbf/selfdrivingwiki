---
timestamp: 2026-10-04T120000Z
title: Ingestion jobs fail on agent launch failures instead of completing
branch: bugfix/ingest-launch-failure-completion
status: complete
issue: https://github.com/tqbf/selfdrivingwiki/issues/1354
---

# Ingestion jobs fail on agent launch failures instead of completing

## Progress

Issue #1354: job `01M42E58RKD5T5TY0YD54FWDKS` settled `.completed` about
2.4 seconds after start. The wrapper stderr read `env: node: No such file
or directory`. No agent turn ran. The job still stamped its sources as
ingested.

Root cause, in three parts:

1. The multi-phase ingest path swallows the launch error. `runPhase`
   caught `ACPBackendError.launchFailed`, logged it, and returned
   `.failed`. The planner failure moved the run to the single-session
   fallback. The fallback also failed. Its else branch called
   `finish(status: -1)` and set no `preflightError`. So the diagnostic
   (`env: node: ...`) never reached the launcher state that hosts read.
2. `AppQueueIngestionProvider.validateLauncherOutcome` rejected a nonzero
   exit only when `runHadTurnFailure` was true. A launch failure produces
   exit `-1` with no turn failure, so the validator accepted it. The
   success path then stamped sources and the queue marked the item
   completed.
3. The daemon validator had the same gap for the nonzero-exit case. It
   checked `preflightError` first, but a nonzero exit with no turn
   failure still passed.

The fix:

- `AgentLauncher` records the last non-quota phase failure message
  (`lastPhaseFailureMessage`). `runACPIngestFallback`'s failure branch
  copies it into `preflightError` before `finish(status: -1)`.
  `resetRunArtifacts()` clears it per run. A quota fallback that later
  succeeds cannot poison a good run, because validators read only
  `preflightError`.
- Both host validators now use the same contract. Preflight first: a
  recorded launch failure is terminal, whatever the exit status says.
  Then a strict nonzero-exit check: every successful completion path
  finishes with status 0, so nonzero always means an abort (user stop,
  safety-net teardown, spawn failure). `runHadTurnFailure` only selects
  the message. The daemon validator moved to a static internal seam
  (`DaemonQueueIngestionProvider.validateLauncherOutcome`) so tests can
  pin it without a full daemon.
- Sources are safe by ordering: `validateLauncherOutcome` throws before
  `stampIngestedSources` runs, so a launch failure stamps nothing.

Environment note: this change makes the missing-Node failure visible in
the queue error and job view. It does not repair the daemon PATH itself.
The spawn environment builds its PATH from the login-shell hop
(`AgentRunContext.effectivePATH`). When that hop fails, the inherited
launchd PATH has no Node. That investigation stays open (see "Open
work").

## Verification

- `AgentLauncherLaunchFailureCompletionTests` drives the real
  multi-phase path with a failing `FakeAgentBackend`. It pins the exact
  observed tuple: `exitStatus == -1`, `preflightError != nil`,
  `runHadTurnFailure == false`, and the validator rejects that state. A
  second test pins the recovery: planner fails, fallback succeeds, the
  run completes with status 0 and the validator accepts it.
- `AppQueueIngestionProviderStagingTests` gained the validator cases:
  launch failure with exit `-1` and zero turns throws with the captured
  diagnostic. Nonzero exit with no diagnostic also throws. The success
  tuple still passes.
- `DaemonQueueIngestionValidatorTests` pins the same contract for the
  daemon host.
- `QueueEngineTests.testLaunchFailureSettlesFailedWithDiagnostic` pins
  the full queue outcome: the worker throws `spawnFailed` with the
  diagnostic, the item settles `.failed`, and the store keeps the
  stderr text.
- `make test` passes. `WIKIFS_APP_TESTS=1 swift test` passes except two
  failures that also fail on the base commit `e7d319d9`
  (`mimeExplicitParamOverridesSniff`, deterministic and unrelated, and a
  `RaceFreeProcessGroupRunnerTests` timeout that passes in isolation).

## Open work

- Verify Node resolution under the app and daemon launch environment
  (issue #1354, acceptance criterion 6). The failure is now visible and
  actionable, but the PATH hop can still fail in a launchd context.
- Audit the affected wiki (`01M41BV9H7N34EAW18R7G9SQEP`) for source
  rows stamped ingested by the failed job, and clear them before retry
  (acceptance criterion 7).
