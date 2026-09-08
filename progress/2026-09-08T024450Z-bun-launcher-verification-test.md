---
timestamp: 2026-09-08T024450Z
title: Bun launcher verification test
branch: feature/issue-1217-bun-launcher-test
status: complete
---

# Bun launcher verification test

Implements the suggested automated test from
[#1217](https://github.com/tqbf/selfdrivingwiki/issues/1217).

## Progress

`ManagedExtractorProcessExecutorTests.bunRuntimeCompletesTerminalFrameAndReapsChild`
resolves bun through the production login-shell locator. The test returns
cleanly when bun is not available. The macOS Swift CI job installs bun 1.4.0,
so CI runs the gated path.

The test launches a real bun process with an allowlisted operation environment.
Its JavaScript entry reads the complete request from standard input and writes
the requested Markdown output. It starts a long-lived child, records its PID,
emits one progress frame and one result frame, and then remains alive.

The test confirms that the terminal result completes the operation before its
60-second limit. It accepts the expected signaled termination after the host
kills the process group. It also confirms that the child process is gone.

The fixture snapshots the operation home, temporary, and cache directories.
The test confirms that bun creates no files or directories there. It also
confirms that each host-created directory keeps mode `0700`.

## Verification

- `swift test --filter ManagedExtractorProcessExecutorTests.bunRuntimeCompletesTerminalFrameAndReapsChild`
  passes with real bun in 2.342 seconds.
- `make build` passes.
- `make test` passes with 4,233 tests in 460 suites. The full suite includes
  the bun test, which passes in 2.656 seconds.
