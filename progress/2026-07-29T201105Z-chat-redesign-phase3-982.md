---
timestamp: 2026-07-29T201105Z
title: Chat redesign Phase 3 daemon controllers (#982)
branch: chat-redesign-phase3
status: complete
---

# Chat redesign Phase 3 daemon controllers (#982)

## Progress

This branch now includes Phase 3 of issue #982.

Phase 3 moves chat lifecycle ownership into one daemon controller per
`ChatID`. The controller now owns session generation, durable queue order,
restart recovery, active-turn lifecycle, permission state, cancellation,
terminal-outcome winner selection, typed snapshots, and bounded replay.

The daemon now routes one typed submit path for draft, warm, dead, and
persisted chats. The app no longer chooses start-vs-continue lifecycle
branches before the daemon. The compatibility surface still uses the current
XPC `Data` transport and the current `RemoteChatSession` / `ChatDetailView`
adapters. That Phase 4 work stays out of scope here.

## What changed

- Added [`Sources/wikid/DaemonChatController.swift`](../Sources/wikid/DaemonChatController.swift).
  The controller owns one chat session generation and one replay buffer.
- Added [`Sources/wikid/LauncherChatAgentRuntime.swift`](../Sources/wikid/LauncherChatAgentRuntime.swift).
  This runtime keeps the launcher-backed provider path behind the typed
  runtime protocol.
- Reworked [`Sources/wikid/DaemonChatHost.swift`](../Sources/wikid/DaemonChatHost.swift)
  to use per-chat controllers and one typed submit entrypoint.
- Routed the typed submit request through the daemon contract, workload
  client, app coordinator, and `ChatDetailView` draft/live compatibility path.
- Kept the explicit queued-turn mutation boundary. `cancel()` no longer
  removes a queued active turn. Queued-turn removal stays on the separate
  queue mutation path.
- Hardened restart recovery. On daemon restart, claimed in-flight turns are
  marked interrupted, provider session ids are cleared, queued turns keep
  order, and the controller does not auto-resubmit.
- Hardened stale and late event handling. The controller ignores stale
  generations and keeps one terminal winner across completion, cancellation,
  and later transport close.
- Replaced new bare `try?` swallow points in the Phase 3 daemon path with
  logged best-effort handling.

## Test coverage

Added direct controller coverage in
[`Tests/WikiFSAppTests/DaemonChatControllerTests.swift`](../Tests/WikiFSAppTests/DaemonChatControllerTests.swift)
for these Phase 3 cases:

- restart interruption marks the claimed turn failed and clears the stored
  provider session id
- queued active turn cancel is a no-op
- duplicate submit commands do not enqueue or submit twice
- queued follower cancel does not cancel the active in-flight turn
- permission request and resolution update attention and forward typed options
- stale generation runtime events are ignored
- stored provider session ids flow into runtime start requests for resume
- bounded replay becomes unavailable past the retained window
- restart keeps queued turn order and does not auto-resubmit
- completion wins over later transport close
- cancellation wins over a completion race

Focused app coverage also stayed green for the host and coordinator seams:

- `DaemonChatControllerTests`
- `ChatDaemonCoordinatorTests`
- `DaemonChatHostTests`
- `RemoteChatSessionTests`

## Verification

Verified on Wednesday, July 29, 2026 from this worktree:

- `make prompts` passed.
- `make build` passed.
- `make test` passed with `2669 tests in 216 suites`.
- `WIKIFS_APP_TESTS=1 swift test --filter 'DaemonChatControllerTests|ChatDaemonCoordinatorTests|DaemonChatHostTests|RemoteChatSessionTests'`
  passed with `87 tests in 4 suites`.

The full app-hosted run did not complete locally:

- Raw `WIKIFS_APP_TESTS=1 swift test` stalled with `swiftpm-testing-helper`
  still alive and no new output.
- `env WIKIFS_APP_TESTS=1 TEST_TIMEOUT=60 make test-watchdog` timed out with
  wrapper exit `124`.
- The watchdog log is
  `tmp/test-logs/swift-test-20260729-130936.log`.
- The watchdog log shows no deterministic suite failure before timeout. It
  also shows `Suite WikiDaemonConnectionHealthTests passed after 20.325 seconds`.

## Phase 4 and later

This branch does not do Phase 4 or later work.

- It does not replace the chat XPC wire format.
- It does not replace `RemoteChatSession` with a pure client reducer store.
- It does not decompose `ChatDetailView` into the Phase 5 presentation split.
- It does not remove compatibility adapters that still bridge the current app
  UI to the new daemon-owned controller model.
