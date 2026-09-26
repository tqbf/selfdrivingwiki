timestamp: 2026-09-26T154800Z
title: Orphaned uv extractor wrappers are reaped at quit and at daemon startup
branch: fix/reap-orphaned-extractor-wrappers
status: complete
---

# Orphaned uv extractor wrappers are reaped at quit and at daemon startup

Issue #1330. Design and rationale: `plans/orphan-extractor-wrapper-reaping.md`.

## Progress

An extractor operation runs as `uv run --script <operation>/package/bin/<tool>`.
The host spawns it as its own process group. When the daemon died mid-operation,
no one killed that group, and the wrapper stayed alive with no parent. Nine
such wrappers survived the Zotero incident. On 2026-09-26 this machine still
held 11 of them, some from Tuesday.

Two changes close the leak:

1. **Quit backstop.** `RaceFreeProcessGroupHandle` now registers every verified
   group in a process-global `OwnedProcessGroupRegistry`. It deregisters at
   observed leader exit or handle teardown. The wikid quit seam and the app
   close seam call `terminateAllOwnedGroups()` as their last synchronous act
   before exit: verified SIGTERM, one bounded grace, verified SIGKILL. Before
   this, the kill depended on a cooperative-pool job that a process exit did
   not wait for.

2. **Startup sweep.** The daemon sweeps the process table for orphaned
   wrappers before `cleanupOperationSessions(.staleSessions)` deletes their
   operation directories. A process is reaped only when it runs under the
   current user, is not the caller, has a process group id above 1, and its
   arguments reference `…/operations/<role>/<pid>-<uuid>/…` under this
   container's operations root with a dead owner pid (or an own-pid reuse
   under a different session). The dead-owner check, not the path match, is
   the safety rule.

`operationSessionIsStale` now shares a validated `<pid>-<staging-id>` parser
(`ExtractorOperationSessionName`) with the sweep.

## Evidence

- `make test` green, 4153 tests.
- New suites: `OwnedProcessGroupRegistryTests` (6 tests, one real
  `/bin/sleep` group killed through the registry's verified kill),
  `ExtractorOrphanWrapperReaperTests` (15 tests, one real `yes` group killed
  by the sweep).
- `ProcessSignalSafetyAuditTests` review entries added for the four new
  `kill` call sites.
- A full-suite run caught one real test-design hazard: the registry is
  process-global, so a test that called `terminateAllOwnedGroups()` could
  kill fixture groups registered by parallel suites in the same target. The
  integration test now uses the registry's scoped kill primitive instead.

## Follow-ups

- The issue's second problem (about four minutes between markdown persist and
  item completion) is not explained by the kill path: the executor-side settle
  is bounded by the 1 s cancel grace plus the 2 s exit grace. The gap lives
  downstream (persist, report writes, output drain) and needs its own
  measurement.
- `AsyncProcessRunner` (ingestion spawn path) has no quit backstop of its
  own. Nothing observed leaks through it yet.
