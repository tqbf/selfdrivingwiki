---
timestamp: 2026-09-28T070000Z
title: skip process-spawning suites on the 3-vCPU CI runner (#1338)
branch: chore/skip-process-suites-in-ci
status: complete
---

# Skip process-spawning suites on the 3-vCPU CI runner (#1338)

`RuntimeCommandLocatorIntegrationTests` and
`ManagedExtractorProcessExecutorTests` no longer run in the broad CI
core-suite step. The step's skip list in `.github/workflows/ci.yml` names
both suites. The suites are not disabled. They still run locally before
every PR (`make test`).

## Progress

- Both suites spawn real subprocesses under wall-clock deadlines. The
  locator suite waits for a zsh login shell within a 10 s startup window
  (`shellStartupTimeout`). The executor suite gives the fixture process a
  30 s operation limit.
- The CI `swift` job runs about 420 suites on a 3-vCPU `macos-latest`
  runner. Under that load, a child process can fail to start within its
  deadline. The deadline error then replaces the error the test expects,
  so the test fails.
- Evidence: PR #1336 run 36384354347 (2026-09-28) failed both suites, and
  a rerun with no code change passed. Main run 35458552040 (2026-09-19)
  failed the zsh locator test. Main run 35392870199 (2026-09-18) failed
  the malformed-protocol test.
- The deadline budget was already raised once (5 s to 30 s on 2026-09-24,
  see the comment in `ManagedExtractorProcessExecutorTests.swift`). The
  2026-09-28 failure beat the raised budget, so a bigger budget is not a
  fix. Issue #1338 tracks the permanent options.

## Verification

- `swift test --filter '<both suites>' --skip '<both suites>'` runs no
  tests, which proves the skip pattern matches both suite names.
- Without the skip, the same filter runs 28 tests and both suites pass
  locally in about 33 s.
- `swift test --filter progressEntriesFollowTemplate` passes with this
  entry in place.
