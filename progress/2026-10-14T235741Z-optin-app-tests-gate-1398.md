---
timestamp: 2026-10-14T235741Z
title: Opt-in app test gate fails loudly when WikiFSAppTests does not execute
branch: bugfix/optin-app-tests-silent-skip
status: complete
---

# 2026-10-14 — Opt-in app test gate: fail loudly when WikiFSAppTests does not execute (#1398)

## Progress

A `WIKIFS_APP_TESTS=1 swift test` invocation once exited 0 with ZERO
`WikiFSAppTests` test lines. The opt-in target silently did not execute, yet
the run was green. A later invocation on the same tree ran the target
normally. CI's `make test` excludes the app target, so a developer who
trusted that green run had verified nothing.

## Diagnosis

The opt-in graph is wired in `Package.swift`: when the environment does not
say `WIKIFS_APP_TESTS=1`, the manifest filter drops the `WikiFSAppTests`
target from the package graph. The evaluation result feeds SwiftPM's caches
(shared manifest cache `~/Library/Caches/org.swift.swiftpm/manifests`,
build-plan layers), none of which are visible to `swift test`'s exit code.

What was checked:

- On the current toolchain (Swift 6.4), the shared manifest cache includes the
  environment in its key (verified live: `swift package dump-package` flips
  the target in and out as the flag flips). Back-to-back poisoning did not
  reproduce.
- The false-green log from 2026-10-10 no longer exists in `tmp/test-logs/`,
  so the exact trigger cannot be reconstructed. Candidate mechanisms that
  remain consistent with "intermittent, same tree": an older toolchain whose
  manifest cache predates environment-aware keying, a stale build-plan layer,
  or an environment-stripped wrapper.

Conclusion: the trigger is not reproducible with the evidence at hand, so the
fix is structural and mechanism-independent. Whatever layer drops the bundle,
the observable contract is now enforced on the run log.

## Fix

The contract from #1398: when `WIKIFS_APP_TESTS=1`, the invocation either
demonstrates that the app target executed, or FAILS loudly. Never a silent
green.

- `Tests/WikiFSAppTests/OptInGateSentinelTests.swift` — the sentinel. A
  dependency-free test inside the app target whose executed line proves the
  target ran. It also fails if the target executes while the flag is unset
  (the mirrored anomaly).
- `scripts/lib/optin-app-test-gate.sh` — the assertion. Counts executed
  ("passed after"/"failed after") log lines matching the expectation (the
  sentinel, by default). Zero matches fail the invocation even when
  `swift test` exited 0. "started." lines are counted only for diagnostics;
  they do not satisfy the gate.
- `scripts/test-optin-app-tests.sh` — the guarded runner. Sets the flag,
  tees the log to `tmp/test-logs/optin-app-tests-*.log`, runs `swift test`,
  enforces the gate, and propagates exit codes. Narrowed runs pass
  `--expect REGEX` with the suite they expect to execute.
- `Makefile` — `test` delegates to the guarded runner when
  `WIKIFS_APP_TESTS=1`; new `test-app` target runs the opt-in tier without
  needing the env prefix.
- `scripts/test-with-watchdog.sh` — applies the same gate to
  `make test-watchdog` runs when the flag is set.
- `Tests/WikiFSTests/OptInAppTestsGateContractTests.swift` — the always-run
  default graph pins the wiring (manifest conditional, sentinel, gate
  library, runner, Make recipes, watchdog hook) so a refactor cannot
  disconnect the gate silently.

Bare `swift test` without a wrapper stays outside the gate's reach by
construction: SwiftPM offers no post-run hook, and the manifest cannot
observe a stale evaluation of itself. Every documented invocation path
(`make test`, `make test-app`, `make test-watchdog`) is guarded.

## Relationship with #1422

#1422 is the twin failure: the app runner dies MID-RUN with exit 0 and no
summary, dropping hundreds of already-scheduled tests. Mechanism differs
(graph or plan-level skip vs runner death). The gate counts execution
evidence, so a mid-run death that executed some tests still passes it; the
missing-summary half of #1422 needs its own guard (started-vs-summary
reconciliation) and remains open.

## Verification

- Unit: the gate library passes on a sentinel-executed log, fails on a
  started-only log, and honors narrowed expectations.
- Forced skip: `scripts/test-optin-app-tests.sh --filter` to a default-graph
  suite runs with the flag set but zero app tests executed; the invocation
  fails with the gate message.
- Normal path: the guarded opt-in run with the sentinel executes the app
  target and passes; full `make test` stays green.
