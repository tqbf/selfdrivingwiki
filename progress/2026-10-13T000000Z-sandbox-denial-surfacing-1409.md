---
timestamp: 2026-10-13T000000Z
title: Surface Seatbelt sandbox denials in probe and chat launch failures (#1409)
branch: fix/sandbox-denial-surfacing
status: complete
---

# Surface Seatbelt sandbox denials in probe and chat launch failures (#1409)

## Progress

When a sandboxed adapter spawn fails, the surfaced error was the adapter's
own cryptic message (for example "Cannot call write after a stream was
destroyed"). The real cause was a kernel denial in the unified log, logged
milliseconds earlier, reachable only by a manual `log show` dig.

New `SandboxDenialReporter` (WikiFSEngine):

- `parseDenials` (pure) keeps log lines carrying a `deny(` marker and any
  lowercase token, normalizes each to `deny <operation> <path-or-argument>`,
  dedupes on the normalized line, and caps the result.
- `recentDenials` runs ONE `log show --style compact` over the launch
  window (one second of slack, clamped to a five-minute lookback) with a
  deny+token predicate, raced against a hard bound (8 s) via unstructured
  tasks, so a caller that is itself being cancelled cannot take the query
  down. The production invocation is `AsyncProcessRunner` (non-blocking,
  cancellation-terminating). Tokens are the spawn argv basenames plus the
  `providerHomeSubpaths` values.

Wiring:

- `ACPProviderModelProbe.runProbe` records the launch instant, queries the
  reporter in its launch/initialize catch (skipped when the task is already
  cancelled), appends the denials to the `.launchFailed` message, and logs
  each line through `DebugLog.agent`. The query is an injectable init seam.
- `ACPBackend.startProcess` does the same in its catch and carries the
  denials on a new `ACPBackendError.launchFailed(sandboxDenials:)`
  associated value, rendered by `errorDescription`. The backend gets the
  same injectable seam, mirroring `resolveBunRuntime`.

Attribution is window+token, not pid-perfect (the ACP SDK client does not
expose child pids); the tradeoff is documented on the reporter type.

## Verification

- `make build` green.
- `make test` green: 4600 tests in 471 suites (default target graph).
- `WIKIFS_APP_TESTS=1 swift test --filter ACPProviderModelProbeTests`
  green: 32 tests in 2 suites, including the two denial-surfacing tests.
- Full-suite note: the first runs on this branch failed the load-sensitive
  `QuitBackstopEndToEndTests` sweep. The cause was this suite's parallel
  task churn (a 30 s parked seam task plus concurrent tests) starving the
  cooperative pool the shared-registry sweep depends on. The suite is now
  `.serialized` with a small bounded task, and the full run is green
  (baseline comparison on unmodified main: green both before and after).
