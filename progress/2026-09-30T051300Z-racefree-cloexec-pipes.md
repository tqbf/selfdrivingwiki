---
timestamp: 2026-09-30T051300Z
title: Close-on-exec pipe descriptors in the race-free process group runner
branch: bugfix/issue-1334-cloexec-pipes
status: complete
---

# Close-on-exec pipe descriptors in the race-free process group runner

## Progress

The runner no longer leaks pipe descriptors into concurrently spawned
children (issue #1334).

- Every pipe descriptor the runner creates now carries `FD_CLOEXEC`. A
  `posix_spawn` in this process cannot inherit a pipe end that belongs to
  another launch. Before the fix, an inherited stdin write end kept the
  child's stdin pipe open past the parent's close, so the child never saw
  EOF. An inherited stdout or stderr write end delayed the parent's own
  drain the same way.
- The spawn attributes now set `POSIX_SPAWN_CLOEXEC_DEFAULT`. The child
  closes, at exec, every descriptor that no file action mentions. This
  covers the window between another launch's `pipe()` call and its
  `fcntl(F_SETFD)` call. The per-descriptor flag cannot cover that window.
- The `dup2` file actions still build the child's stdio. `dup2` clears
  close-on-exec on its target, so descriptors 0, 1, and 2 survive exec.
  The `addclose` loop stays as a second layer.
- The pipe block now uses named pipe ends (`stdinPipe.readFD`) in place of
  bare index pairs.

## Verification

- New regression test `concurrentLaunchesDoNotStarveEachOthersStdinEOF` in
  `RaceFreeProcessGroupRunnerTests`. It launches two `/bin/cat` children at
  one shared deadline for ten rounds. Both children must echo their own
  input and exit within five seconds.
- Mutation check: with the fix stashed, the test fails on round one with
  `.timedOut` after ten seconds. With the fix, all rounds pass in under
  one second.
- `make test` passes.

The quit-backstop end-to-end suite keeps its spawn jitter and retry. Its
doc now records the race as fixed and the jitter as belt-and-braces.
