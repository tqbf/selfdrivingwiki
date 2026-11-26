---
timestamp: 2026-11-26T22:11:07Z
title: Store tier trap is mid-run; crash diagnostics capture added
branch: chore/ci-crash-diagnostics-capture
status: active
---

# Store tier trap is mid-run; crash diagnostics capture added

## Progress

Forensics on CI run 45374149667 corrected the P7 record's reading of the
daemon store integration tier crash. The swiftpm-testing-helper traps with
SIGTRAP while tests are still executing: 75 tests started, 72 passed, and 4
of 7 suites finished when the helper exited. The earlier "teardown after all
tests pass" reading came from buffered output. Three local runs of the exact
CI filter inside the Tart VM (macOS 26.4 / Xcode 26.5 vs CI 26.7.2 / 26.6)
are green, so the trap is unreproduced locally.

Archived `.ips` reports from 2026-11-22 are unrelated: one shows a
mutation-testing mutant feeding a negative recv length into
`Data.removeSubrange` (`SearchSocketWire.swift`), and one is an array bounds
trap in `ProjectionTreeTests`. No evidence connects the store-tier trap to
the File Provider projection startup wedge (run 45364281147).

Candidate: the store-tier fixture runs an in-process Unix socket server whose
stop path cancels Dispatch sources and closes descriptors without waiting for
cancellation handlers. Untested without a stack.

`.github/workflows/ci.yml` now collects a diagnostics bundle on every run of
the swift job: fresh `.ips` files (marker-file window), the opt-in runner's
tee'd logs from `tmp/test-logs/`, a bounded unified-log window, and a dSYM
for the package test bundle. The bundle uploads as a `crash-diagnostics-*`
artifact, so the next trap lands with a symbolication-ready stack.

## Verification

- `make test`: green locally.
- `ci.yml` parses (ruby YAML check). actionlint is not installed locally.
- Investigation artifacts: `tmp/teardown-investigation/` (gitignored) holds
  the guest run logs and both CI run logs.
