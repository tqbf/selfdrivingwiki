# Reaping orphaned extractor wrapper processes (#1330)

## Problem

An extractor operation runs as `uv run --script <operation>/package/bin/<tool>`.
The host spawns it with `POSIX_SPAWN_SETPGROUP`, so the wrapper leads its own
process group. When the daemon dies while an operation is in flight, no one
kills that group. The wrapper stays alive with no parent. It holds memory and
a process slot, and it does no work. Over several daemon generations the
wrappers accumulate.

Two paths leak today:

1. **Clean quit does not wait for the kill.** The quit chain cancels worker
   tasks and then calls `Darwin.exit`. The group kill runs inside
   `RaceFreeProcessGroupHandle.result` on a cooperative-pool thread
   (`terminateAfterFailure`). If the process exits before that job runs, the
   `kill` syscall never happens. `RaceFreeProcessGroupHandle.deinit` does not
   kill either.
2. **A crash cannot run any code.** Nothing in the dying process can help.

The evidence and design sketch come from the Zotero incident (2026-09-24,
issue #1330). Nine wrappers survived their daemon. Every wrapper pointed at an
operation directory that the system already deleted.

## Fix

Two mechanisms, one per leak path.

### 1. Clean quit terminates the groups it owns

`RaceFreeProcessGroupHandle` gains a process-global registry
(`OwnedProcessGroupRegistry`). A handle registers its verified group identity
at spawn. It deregisters when the kernel reports the group leader exit, or
when the handle goes away.

The quit path calls `OwnedProcessGroupRegistry.terminateAllOwnedGroups()` as
its last step before `Darwin.exit`. The call is synchronous: verified SIGTERM
to every registered group, one bounded grace sleep, then verified SIGKILL to
the groups still alive. It uses the same identity checks as the handle
(`ProcessSignalSafety.verify`), so PID reuse cannot redirect a signal.
When the normal settlement already ran, the registry is empty and the call is
a no-op.

The wikid XPC quit seam (`DaemonProcessLifetimeCoordinator.didShutdown`) and
the app close seam (beside `cleanupOperationSessions(.currentSession)`) both
call it. `kill` delivery does not depend on the caller staying alive, so the
signals land even though the process exits right after.

### 2. The next daemon generation reaps strays

A new daemon startup step sweeps the process table for orphaned wrappers
before `cleanupOperationSessions(.staleSessions)` deletes their operation
directories.

The wrapper command line and environment encode the owning daemon:
`…/extractors/v1/operations/<role>/<pid>-<uuid>/…`. The reaper
(`ExtractorOrphanWrapperReaper`) reads the process list with
`sysctl(KERN_PROC_UID)` and each candidate's arguments with
`sysctl(KERN_PROCARGS2)`. It kills a process group only when ALL of these
hold:

- The process runs under the current user ID.
- The process is not the caller.
- The arguments reference an operation path under this container's
  `extractors/v1/operations` root, with a role from the closed
  `ExtractorPackageProcessRole` set.
- The session name parses as `<pid>-<staging-id>`.
- The owning pid is dead (`kill(pid, 0)` fails with `ESRCH`), or the owning
  pid is the caller's own pid under a different session id (PID reuse).

Matches are killed with `kill(-pgid, SIGKILL)`, guarded to `pgid > 1`. A
command-line match alone is not enough. The dead-owner check is what makes
the match safe, and the sweep never touches another user's processes.

The daemon is the designated reaper for every role, not only its own. An
`app`-role wrapper whose app died is a stray the next daemon generation can
reap. A live owner of any role keeps its wrappers.

Linux runs the daemon only as a diagnostic. The reaper is macOS-only there,
with a logged diagnostic line, mirroring the seatbelt precedent.

## Scope limits

- The issue's second problem (slow settle after the terminal frame) is not in
  this fix. The executor-side settle is bounded: 1 s cancel grace, 2 s exit
  grace, pipe drain within the remaining deadline. A 3.5-minute gap between
  markdown persist and item completion must come from downstream work
  (persist, report writes, output drain). It needs its own measurement before
  anyone changes it.
- `AsyncProcessRunner` (ingestion) follows a different spawn path. Its
  shutdown behavior is unchanged here.

## Tests

- Registry: verified SIGTERM then SIGKILL ordering, identity-refused and
  already-exited skips, deregistration, and one real `/bin/sleep` group killed
  through `terminateAllOwnedGroups()`.
- Reaper core: decision table for dead owner, live owner, foreign uid, self,
  own-pid reuse, malformed session name, unknown role, and no match — with an
  injected liveness probe.
- Reaper integration: a real `yes` process group whose arguments reference a
  dead-owner operation path is killed by the sweep.

## Files

- `Sources/WikiFSCore/Extractor/OwnedProcessGroupRegistry.swift` (new)
- `Sources/WikiFSCore/Extractor/RaceFreeProcessGroupRunner.swift` (register
  and deregister)
- `Sources/WikiFSCore/Extractor/ExtractorOrphanWrapperReaper.swift` (new)
- `Sources/WikiFSCore/Extractor/ExtractorDirectoryAdmission.swift` (share the
  `<pid>-<staging-id>` session-name parser)
- `Sources/wikid/main.swift` (startup sweep, quit backstop)
- `Sources/WikiFS/Window/WikiFSApp.swift` (app close backstop)
- Tests beside the existing executor suites
