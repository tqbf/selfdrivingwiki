# CI: skip process-spawning suites on the 3-vCPU runner

Date: 2026-09-28

## What changed

`RuntimeCommandLocatorIntegrationTests` and
`ManagedExtractorProcessExecutorTests` no longer run in the broad CI
core-suite step. The step's skip list in `.github/workflows/ci.yml` now
names both suites. The suites are not disabled. They still run locally
before every PR (`make test`).

## Why

Both suites spawn real subprocesses under wall-clock deadlines:

- The locator suite waits for a zsh login shell within a 10 s startup
  window (`shellStartupTimeout`).
- The executor suite gives the fixture process a 30 s operation limit.

The CI `swift` job runs about 420 suites on a 3-vCPU `macos-latest`
runner. Under that load, a child process can fail to start within its
deadline. The deadline error then replaces the error the test expects,
so the test fails.

Evidence:

- PR #1336 run 36384354347 (2026-09-28): both suites failed. A rerun
  with no code change passed.
- Main run 35458552040 (2026-09-19): the zsh locator test failed.
- Main run 35392870199 (2026-09-18): the malformed-protocol test failed.

The deadline budget was already raised once (5 s to 30 s on 2026-09-24,
see the comment in `ManagedExtractorProcessExecutorTests.swift`). The
2026-09-28 failure beat the raised budget, so a bigger budget is not a
fix.

## Validation

`swift test --filter '<both suites>' --skip '<both suites>'` runs no
tests, which proves the skip pattern matches. Without the skip, the same
filter runs 28 tests and both suites pass locally in about 33 s.

## Tracking

Issue #1338 records the permanent fix options. The recommended option is
a dedicated serialized CI step that runs after the broad step.
