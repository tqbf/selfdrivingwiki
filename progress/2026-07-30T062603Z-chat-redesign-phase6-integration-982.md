---
timestamp: 2026-07-30T062603Z
title: "2026-07-29 — Chat redesign Phase 6 integration (#982)"
branch: chat-redesign-phase6-integration
status: complete
---

# 2026-07-29 — Chat redesign Phase 6 integration (#982)

Local date note: the UTC timestamp `2026-07-30T062603Z` corresponds to
Wednesday, July 29, 2026, 11:26:03 PM PDT (UTC-07:00).

## Progress

Completed the reviewed Phase 6 compatibility cleanup on
`chat-redesign-phase6-integration`.

- Removed the unused app-side start, continue, and send shims from
  `ChatDaemonCoordinator` and its test double.
- Kept the raw `WikiDaemon` XPC start, continue, and send endpoints. Each
  endpoint remains a compatibility adapter over `DaemonChatHost.submitTurn`.
- Replaced host controller and wiki maps with `ControllerRegistry`. The actor
  owns lookup, wiki resolution, timer replacement, cancellation, and removal.
- Added quiescent five-minute controller eviction. A controller remains alive
  while it has an active claim or a durable queued turn.
- Removed obsolete launcher event/state polling and temporary app badge logs.
- Updated the chat API signature manifest after removing migrated commands.
- Added hosted coverage for deterministic quiescent controller eviction.

## Verification

Passed:

- `make prompts`
- `make build`
- `swift test --filter ChatAPISignatureManifestTests`
  - `Test run with 1 test in 1 suite passed`
- `WIKIFS_APP_TESTS=1 swift test --filter 'DaemonChatHostTests|ChatDaemonCoordinatorTests'`
  - `Test run with 32 tests in 2 suites passed`
- `make test`
  - XCTest result: `Executed 9 tests, with 0 failures (0 unexpected)`
  - Swift Testing result: `Test run with 2695 tests in 218 suites passed`
  - final output: `✓ tests pass`
- `WIKIFS_APP_TESTS=1 swift test`
  - began broad hosted execution with no observed Phase 6 assertion failure
  - the SwiftPM test helper remained idle at teardown for 98 seconds and was
    interrupted to preserve the host volume; this is not a passing full hosted
    suite
- `git diff --check`

Timed out:

- `WIKIFS_APP_TESTS=1 TEST_TIMEOUT=60 make test-watchdog`
  - the watchdog terminated its verbose `swift test` subprocess at 60 seconds
  - `tmp/test-logs/swift-test-20260730-000946.log` ended during broad
    app-hosted test execution, with no observed assertion failure
  - this is recorded as the short-deadline hosted watchdog limitation, not a
    successful gate

Capacity-limited:

- `make mutate-scope SOURCES_PATH=Sources/WikiFSEngine` ran with stock
  `swift-mutation-testing 1.3.0` for 38 minutes in its isolated copy.
  It continued launching fresh `WikiFSCoreTests` mutant checks but produced no
  report before host free space fell to 3.2 GB. The run was interrupted
  gracefully to preserve capacity for the required final SwiftPM build and
  test matrix. This is not a passing mutation result.

## Review

The final SwiftUI/macOS review found no Phase 6 presentation regression.
`ChatDetailView` remains the Phase 5 composition root, and it submits typed
`ChatSubmitRequest` values through the coordinator.

The final concurrency review found the registry timer ownership sound after
the direct actor hop. The actor cancels a prior timer before it stores the new
timer. The host only removes a controller after `closeIfIdle()` confirms no
active claim and no queued durable turn.
