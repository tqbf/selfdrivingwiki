---
timestamp: 2026-07-11T150408Z
title: "2026-07-11 — ACP stall recovery: watchdog kill escalation (#334 Phase 3)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — ACP stall recovery: watchdog kill escalation (#334 Phase 3)

## Progress


**Problem:** Phases 1 + 2 fixed the stall detection, recovery, and root causes.
But if the ACPBackend watchdog's `cancelSession` fails to unblock `sendPrompt`,
and the SDK's `terminate()` also fails (the process is truly wedged), the agent
process stays alive with no way to kill it. The launcher watchdog was log-only.

**Phase 3 fix:**

- **Stall escalation in `startCompletionWatchdog`:** when `isRunning` and idle
  exceeds `watchdogStallThreshold` (180s — more generous than ACPBackend's
  per-turn 120s, this is the backstop), the watchdog calls `stopAgent()` (cancel
  + finish) and spawns a separate kill-escalation task. A `watchdogHasEscalated`
  flag prevents double-escalation. Reset in `resetRunArtifacts()` + `finish()`.
- **Kill escalation (`startKillEscalation`):** runs as a separate Task because
  `stopAgent()` sets `isRunning = false` (which exits the heartbeat loop). Checks
  `kill(pid, 0)` directly — not `isRunning` — to detect whether the process is
  actually dead. Escalation sequence: wait 10s for cancel → `kill(-pid, SIGTERM)`
  (process group) → wait 5s → `kill(-pid, SIGKILL)`. The `terminationHandler`
  fires after the kill → `onExit` → `finish()`.
- **Pure decision helper:** `shouldEscalateWatchdog(isRunning:idleSeconds:
  stallThreshold:alreadyEscalated:)` — extracted as a `nonisolated static` so
  it's unit-testable without driving launcher state. `watchdogStallThreshold`
  is also `nonisolated static`.
- **Debug cleanup:** stripped the two noisy TEMP DEBUG lines that dumped raw
  `session/update` JSON (800-char prefix) and per-event descriptions — too
  verbose for production. Kept the lifecycle markers (start/send/cancel/
  heartbeat) which were essential for diagnosing the original incident.

**Tests (7 new):** `WatchdogEscalationTests` — escalate at/above threshold,
don't escalate when not running / below threshold / already escalated / no
activity record.

**Gate:** `swift build` clean; fast tier **2147 tests in 181 suites pass**.

**Files changed:**
- `Sources/WikiFS/AgentLauncher.swift` — stall escalation + kill sequence +
  `watchdogHasEscalated` flag + pure decision helper.
- `Sources/WikiFS/ACPBackend.swift` — stripped 2 noisy TEMP DEBUG lines.
- `Tests/WikiFSTests/WatchdogEscalationTests.swift` (new) — 7 tests.

## Verification

Historical verification remains in the progress record above.
