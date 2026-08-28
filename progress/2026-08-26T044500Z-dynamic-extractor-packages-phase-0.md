---
timestamp: 2026-08-26T044500Z
title: Dynamic extractor packages Phase 0 process boundary
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 0 process boundary

## Progress

Phase 0 proved the production process boundary for dynamic extractor packages.

The signed application invoked the embedded `wikid.xpc` through its production Mach service. The service resolved reviewed package bytes from its XPC bundle. It created an owner-only operation directory in the configured App Group.

The service exchanged bounded JSON Lines with a no-dependency fixture. It then terminated a verified process group that contained the fixture and its child.

## Existing behavior baseline

The PDF resolver supports local pdf2md, ACP, Anthropic, Gemini, and Docling Serve. Queue extraction preserves readiness checks, setup messages, progress events, cancellation, failures, backend identity, model identity, and tool provenance.

HTML selection remains separate. The user can select Defuddle or tag-based extraction. Defuddle failures return to tag-based extraction. Direct HTML extraction remains outside the PDF-coupled queue path.

The Activity window shows extraction progress, failure, cancellation, retry, and setup actions. Source detail shows a compact extraction state. Existing provenance distinguishes built-in backends, tools, models, and legacy techniques.

## Process boundary

`RaceFreeProcessGroupRunner` uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP`. It accepts an absolute executable path and does not use a shell.

The runner verifies the group leader PID, parent PID, and kernel start time before group termination. It sends `TERM`, waits for a fixed grace period, then sends `KILL` to the same owned group.

Continuous pipe handlers collect bounded output. The result path does not call a blocking tail read. Cancellation-safe continuations bound exit and pipe-drain waits.

Timeout and failure paths terminate the verified group before they return. The XPC client also bounds the reply, error, and timeout race with one continuation resume.

The retained script is `scripts/test-signed-wikid-extractor.sh`. The opt-in test is `SignedWikiDExtractorLaunchTests`.

## Defects found during the proof

The first exit source used `waitpid` with `WNOHANG`. An exit event could arrive before that call reaped the child. The private exit queue now uses one blocking `waitpid` after the kernel exit event.

The first result path called `FileHandle.readToEnd()`. A surviving descendant could keep the pipe open and block a cooperative worker. The result path now waits for bounded asynchronous pipe EOF.

The first fixture child used Foundation `Process`. That child entered a different process group. The fixture now uses plain `posix_spawn` and inherits the owned group.

## Verification

The following checks passed:

- `swift test --filter RaceFreeProcessGroupRunnerTests`
- `swift test --filter 'ProcessSignalSafetyAuditTests|ExtractorPackageArchitectureBoundaryTests|RaceFreeProcessGroupRunnerTests|SignedWikiDExtractorLaunchTests'`
- `scripts/test-signed-wikid-extractor.sh`
- `make build`
- `make test`
- `git diff --check`

The signed report set all five gate fields to `true`. It reported no diagnostics.

The final full test run passed 3,676 tests in 379 suites.

No fixture child remained after the test run. The unrelated `mise.lock` remains untracked and unchanged.
