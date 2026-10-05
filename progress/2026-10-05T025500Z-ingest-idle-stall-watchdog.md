---
timestamp: 2026-10-05T025500Z
title: Queued ingest idle-stall watchdog and honest failure reason
branch: bugfix/issue-1364-executor-stall-watchdog
status: in-review
---

# Queued ingest idle-stall watchdog and honest failure reason

Issue: #1364

## Progress

### What failed

A 61-source queued ingestion run died on 2026-10-04. Turn 1 hit the 600 s turn
ceiling and recovered. Turn 2 completed. A fresh-start executor then stalled
with its event count frozen and died by signal about 4 minutes into its turn.
The queue item failed with `exit status -1`. Three defects made this run hard
to diagnose:

1. The stall had no liveness bound. The turn watchdog checked only the total
   turn ceiling, and the launcher heartbeat was telemetry only.
2. No log line recorded the terminal transition. The pid, the phase, and the
   cause of death were all absent.
3. The recorded reason blamed the wrong failure. `hadTurnFailure` was sticky
   across the run, so the recovered turn-1 ceiling kill labeled the later
   signal death.

### The fix

**Idle-stall bound for queued lanes.** `TurnLivenessPolicy` now decides
`idleStallExceeded(idleSeconds:)` from an `idleTimeout` and the fanout's last
activity time. `queuedIdleStallTimeout` is 300 s. `idleStallTimeout(for:)`
returns nil for `.chat` and 300 s for `.ingest` and `.lint`, so interactive
chat keeps no idle bound. The `ACPBackend.send` watchdog enforces the decision
through the same recovery path as the ceiling: cancel the session, emit
`.turnFailed(.stalled(idleSeconds:))`, finish the stream. `TurnFailureReason`
already had a `.stalled` case with the same payload, so the fix reuses it.

**Terminal transitions logged.** The backend logs pid, status, and reason at
every exit choke point: `cancel()`, `shutdown()`, and the natural-death catch
in `send()`. `QueueEngine` logs the terminal write for each item with the
cause that committed it. The SDK (`wsargent/swift-acp`) owns the process
`terminationHandler` internally and surfaces no exit callback, so the backend
choke points are the closest seam to the process that this repo controls.

**Honest failure reason.** The launcher records whether a clean turn end
followed the last `.turnFailed` (`runRecoveredAfterTurnFailure`), and derives
`runTurnFailureFact`. The fact is one of three states: no turn failure
observed, a failure recovered by a later clean turn end, or a failure never
recovered. A `.messageStop` whose previous event was not the failing turn's
own `.turnFailed` tail marks the recovery. Each new `.turnFailed` resets the
recovery, so the fact describes only the last failure. The validator takes
the fact and selects one of three messages: the ceiling message for an
unrecovered failure, "failed after recovering from an earlier turn failure"
for a recovered one, and "aborted before completing" when no turn failed.
The validator states what the launcher observed. It does not infer a cause
from the exit-status sign: every negative status is synthesized by the
launcher, so a "process died" claim is a fact the validator cannot know.
Pass and fail decisions do not change.

## Verification

- 9 new `TurnLivenessPolicy` tests: idle bounds, nil disables the check,
  precedence under `promptDone` and ceiling, resolver pins per kind.
- Idle wiring pins on all three launcher paths in
  `AgentLauncherCeilingWiringTests`.
- Recovery-flag tests through the real `run()` with a fake backend: the
  recovered case, the unrecovered case, consecutive failed turns, and the
  fail→clean→fail case that pins the reset.
- An end-to-end watchdog test (`ACPIdleStallWatchdogTests`): a fake ACP agent
  subprocess completes the handshake, then goes silent on `session/prompt`;
  the real `ACPBackend.send` watchdog must emit `.turnFailed(.stalled)` and
  `.messageStop` with tiny injected poll and idle bounds.
- Validator tests in both hosts pin the three-way fact: the ceiling message
  for `.unrecovered`, the recovery message for `.recovered`, and
  "aborted before completing" for `.none` with a negative exit status.

`make build` and `make test` pass. The full default graph runs 4375 tests in
452 suites. The opt-in app graph (`WIKIFS_APP_TESTS=1`) has 11 failing suites
that fail identically on a clean base, so they are environment failures.

Out of scope: the `bun NOT found in Contents/Helpers` launch-check warning
noted in the issue, and any change to the #1363 batch-aware ceiling math.
