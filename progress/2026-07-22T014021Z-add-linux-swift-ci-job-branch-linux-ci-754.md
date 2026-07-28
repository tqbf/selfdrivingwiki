---
timestamp: 2026-07-22T014021Z
title: "2026-07-21 — Add Linux Swift CI job (branch `linux-ci`, #754)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-21 — Add Linux Swift CI job (branch `linux-ci`, #754)

## Progress


**Outcome.** Added a `linux-swift` CI job to `.github/workflows/ci.yml`
that builds and tests the portable `WikiFSCoreTests` target on
`ubuntu-latest` with Swift 6.0. This validates the #754 portability split
and catches Linux-only build breaks early.

**Changes.**
- `.github/workflows/ci.yml`: new `linux-swift` job using
  `swift-actions/setup-swift@v2`, runs `make version prompts` (codegen),
  caches `.build`, `swift build --target WikiFSCoreTests`, then
  `swift test --parallel --skip` with the same skip list as macOS.
- `Tests/WikiFSAppTests/EnvVarHintsTests.swift`: wrapped in
  `#if os(macOS)` — it `@testable import WikiFS` (macOS-only executable).
- `Tests/WikiFSAppTests/WikiDaemonTests.swift`: wrapped in
  `#if os(macOS)` — it `@testable import wikid` (macOS-only executable).
- `plans/linux-ci-runner.md`: plan document.

**Validation.** `swift build` and `swift test` (3333 tests, all pass) on
macOS. The Linux build will be validated by the CI job itself once the PR
is pushed — we cannot test Linux locally on macOS.

## Verification

Historical verification remains in the progress record above.
