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

## PR #990 remediation

The exact-head audit for PR #990 at `49c776d036ebe905a64658c4e96efeedfcfcb226`
was not clean. This remediation pass tightened the controller/runtime boundary
without expanding into the out-of-scope Phase 4 XPC redesign or Phase 5 UI
decomposition.

The main production fixes in this pass are:

- warm follow-up transcript translation now uses the actor-owned active turn id
  instead of capturing the first turn id
- live token and typed transcript deltas are forwarded again from the
  launcher-backed runtime
- pending permissions now translate real `toolCallID`s and typed options and
  reach both the compatibility surface and the typed runtime event stream
- transport close now tears down stale runtime state, rotates generation, and
  forces the next turn onto a fresh runtime
- queue processing now sets a synchronous in-flight guard before awaits to
  prevent duplicate claim/submission races
- failed/interrupted attention no longer blocks later queued turns
- post-claim failures now finish the claimed row instead of orphaning it
- live rehydration merges persisted history with the live overlay instead of
  replacing history with the tail
- live overlay user-message echoes are suppressed so warm follow-ups do not
  duplicate persisted user rows
- controller creation is now serialized inside `DaemonChatHost.makeOrGetController`
- `ToolCallID` identity is preserved across tool-use/result translation and the
  runtime seam has direct production translation tests
- `stopChat` now distinguishes idle/live session close from active-turn
  cancellation via `DaemonChatController.stopSession()`
- compatibility polling now emits only on actual state changes
- rejected controller state-machine updates no longer burn replay/sequence
  numbers and now log the rejection reason
- live overlay memory is bounded and replay capacity is named
- terminal turn cleanup clears `activePermission`
- the hosted timeout test now matches its real invariant: catching the old
  dead-XPC multi-minute hang, not whole-suite scheduler load

Focused evidence added in this remediation pass:

- `LauncherChatAgentRuntimeTests.permissionTranslationPreservesToolCallIDAndTypedOptions`
- `LauncherChatAgentRuntimeTests.transcriptTranslationPreservesToolIdentityAcrossUseAndResult`
- `DaemonChatControllerTests.transportCloseRotatesRuntimeAndRecoversOnNextTurn`
- `DaemonChatControllerTests.stopSessionClosesIdleRuntimeAndNextTurnStartsFreshRuntime`
- `DaemonChatControllerTests.failedTurnAttentionDoesNotBlockNextQueuedTurn`
- `RemoteChatSessionTests.chatPendingPermissionSetsPendingList`

Audit disposition recorded on Wednesday, July 29, 2026:

- `C1` fixed by actor-owned active-turn tracking in
  `LauncherChatAgentRuntime.handleLiveEvent(_:)`.
- `C2` fixed by restoring live event forwarding through
  `AgentLauncher.startInteractiveQuery(... onEvent:onPendingPermission:)` and
  runtime transcript-delta emission.
- `C3` fixed by translating `PendingPermission` into typed
  `ChatPendingPermissionRequest` values with real tool-call ids and options.
- `C4` fixed by `closeRuntimeAndRotateGeneration()` and the stale-runtime
  recovery path.
- `C5` fixed by the synchronous `isProcessingQueue` / claim-state guard before
  awaits in `processQueueIfPossible()`.
- `C6` fixed by promoting claimed queued work after terminal attention and by
  explicit idle/live close handling in `stopSession()`.
- `H1` fixed by finishing the claimed row on any post-claim submission failure.
- `H2` fixed by merging persisted transcript history with the live overlay in
  `chatSessionState()`.
- `H3` fixed by suppressing live `.userText` overlay duplicates and by
  runtime-side first-message history dedup.
- `H4` fixed by serializing `makeOrGetController`.
- `H5` preserved and reverified through the existing shared gate path plus
  `DaemonChatHostTests.daemonChatHostUsesSharedGenerationGate`.
- `H6` fixed by stable tool-call translation ids across use/result.
- `H7` fixed by direct production translation coverage in
  `LauncherChatAgentRuntimeTests`.
- `H8` remained covered by the existing daemon-host preflight rollback path and
  its host/coordinator tests; this remediation did not need new production
  changes there.
- `H9` fixed by separating idle/live `stopSession()` close from active-turn
  cancellation.
- `M2`, `M3`, `M7`, `M9`, `L1`, and `L8` are fixed in the code changes above.
- `L12` is fixed in this progress record and in the plan wording below.

Items not expanded here remained either already fixed on the branch head before
this remediation pass or out-of-scope for production changes in this PR. The
focused suite list above plus the full-repo `make` runs below are the current
evidence set for this exact head.

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
- `WIKIFS_APP_TESTS=1 swift test --filter 'DaemonChatControllerTests|DaemonChatHostTests|LauncherChatAgentRuntimeTests|RemoteChatSessionTests|ChatDaemonCoordinatorTests|ChatAgentRuntimeCoverageTests|WikiDaemonConnectionHealthTests'`
  passed with `101 tests in 7 suites`.

The full app-hosted run did not complete locally:

- Raw `WIKIFS_APP_TESTS=1 swift test` hit a local hosted-suite non-completion:
  one run failed under full load on the old `elapsed < 15` health-check
  assertion, a focused rerun passed immediately, and after widening that test's
  scheduler budget the raw app-hosted run still failed to finish locally.
- The final bounded wrapper run
  `WIKIFS_APP_TESTS=1 TEST_TIMEOUT=60 make test-watchdog` exited `124`.
- The final watchdog log is `tmp/test-logs/swift-test-20260729-144845.log`.
- The wrapper recorded the exact started-but-never-finished tail, including the
  parameterized `PageAuthor` / `SourceProvider` identity tests, chat-domain
  lifecycle parameter suites, and hosted autocomplete/highlight cases.
- The exact local wrapper exit file is
  `tmp/phase3-remediation-logs/make-test-watchdog-final.exit` and contains `2`
  because GNU `make` surfaced the underlying `124` timeout as make failure
  exit `2`.

## Phase 4 and later

This branch does not do Phase 4 or later work.

- It does not replace the chat XPC wire format.
- It does not replace `RemoteChatSession` with a pure client reducer store.
- It does not decompose `ChatDetailView` into the Phase 5 presentation split.
- It does not remove compatibility adapters that still bridge the current app
  UI to the new daemon-owned controller model.
