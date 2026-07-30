---
timestamp: 2026-07-30T050641Z
title: "2026-07-29 — Chat redesign Phase 5 UI decomposition (#982)"
branch: chat-redesign-phase5-ui
status: complete
---

# 2026-07-29 — Chat redesign Phase 5 UI decomposition (#982)

Local date note: the UTC timestamp `2026-07-30T050641Z` corresponds to
Wednesday, July 29, 2026, 10:06:41 PM PDT (UTC-07:00).

## Progress

Implemented the reviewed Phase 5 UI-only decomposition on
`chat-redesign-phase5-ui`.

- Added `ChatDetailPresentation` as the pure app-side projection from Phase 4
  `RemoteChatSession` compatibility state, persisted messages, local draft
  state, and queued follow-ups into content routing, transcript display,
  composer actions, permission visibility, preflight banner text, and outline
  entries.
- Reduced `ChatDetailView` to the composition root for view-local state and
  effects: hydration, live/persisted transcript reloads, right-sidebar
  registration, queued follow-up delivery, quote-anchor handling, submit/retry,
  cancellation, permission resolution, sharing, and reveal actions.
- Extracted focused macOS child views:
  `ChatHeaderSectionView`, `ChatTranscriptPaneView`,
  `ChatComposerPaneView`, and `ChatDetailControlsView`.
- Kept child views data-in / intent-out. They do not read
  `RemoteChatSession` or `WikiStoreModel` as hidden authority.
- Kept queue ownership in the composition root. Broader follow-up queue
  ownership cleanup remains a later compatibility-cleanup item.
- Preserved existing transcript rendering, composer behavior, permissions,
  cancellation, retry/queue behavior, wiki-link syntax, raw identifier formats,
  CLI/File Provider shapes, JSON-encoded `Data` transport, and Phase 4
  synchronization semantics.

## Tests Added First

Added `ChatDetailPresentationTests` under the app-hosted test target. The suite
covers:

- debug/missing/chat content routing
- live transcript selection with timestamp alignment after filtering
- permission visibility only for the live chat
- composer queue/stop/send button projection while a live chat is generating
- queued follow-up suppression once a follow-up is already queued
- persisted outline summary reuse with humanized attachment references

## Verification

Passed:

- `make prompts`
  - exit `0`
  - complete command output: no output
- `make build`
  - exit `0`
  - built and signed `build/Self Driving Wiki.app`
  - output included prerequisite checks, `swift build -c debug`, MLX asset
    bundling, prompt resource bundling, entitlement generation, helper/XPC/
    appex/app codesigning, and:
    `✓ built + signed build/Self Driving Wiki.app (real identity, File Provider enabled)`
- `WIKIFS_APP_TESTS=1 swift test --filter ChatDetailPresentationTests`
  - exit `0`
  - Swift Testing result: `Test run with 7 tests in 1 suite passed`
- `WIKIFS_APP_TESTS=1 swift test --filter 'ChatDetailPresentationTests|ChatDisplayMessagesTests|ChatViewD2Tests|ChatViewPreflightBannerTests|ChatViewDebugFolderButtonTests|ChatRunStateTests|ChatTranscriptFilterTests'`
  - exit `0`
  - Swift Testing result: `Test run with 76 tests in 7 suites passed`
- `swift test --filter 'ChatClientSyncReducerTests|ChatSyncWireTests|RemoteChatSessionTests'`
  - exit `0`
  - Swift Testing result: `Test run with 26 tests in 2 suites passed`
  - note: the filter matched `ChatClientSyncReducerTests` and
    `ChatSyncWireTests`; `RemoteChatSessionTests` is in the app-hosted target
    and is covered by the app-hosted focused/full attempts
- `make test`
  - exit `0`
  - XCTest result: `Executed 9 tests, with 0 failures (0 unexpected)`
  - Swift Testing result: `Test run with 2695 tests in 218 suites passed`
  - final make output: `✓ tests pass`

Initial focused-test repair evidence:

```text
WIKIFS_APP_TESTS=1 swift test --filter ChatDetailPresentationTests

Tests/WikiFSAppTests/ChatDetailPresentationTests.swift:81:33: error: incorrect argument labels in call (have 'optionId:title:kind:', expected 'kind:name:optionId:')
Tests/WikiFSAppTests/ChatDetailPresentationTests.swift:82:31: error: cannot convert value of type 'PermissionOptionID' to expected argument type 'String'
error: fatalError
```

The fixture was corrected to use the ACP model constructor already used by the
existing ACP tests:

```swift
PermissionOption(kind: "allow_once", name: "Allow once", optionId: "allow_once")
```

Repository-authorized app-hosted full-suite evidence:

- command: `WIKIFS_APP_TESTS=1 swift test`
- result: local-environment teardown blocker / authorized waiver
- captured start time: `2026-07-29 21:58:36.376 -0700 PDT`
- visible successful progress included the initial XCTest target:
  `Executed 9 tests, with 0 failures (0 unexpected)`, broad app-hosted suite
  startup, and many passing app-hosted suites including
  `ChatViewD2Tests`, `DaemonChatHostTests`, `ChatDetailPresentationTests`,
  `RemoteChatSessionTests`, hosted SwiftUI suites, queue suites, and store
  suites before output went silent
- after several minutes of no output, `ps` showed the worktree-owned
  `swift-test` and `swiftpm-testing-helper` still alive with `0.0` CPU
- a 5-second sample of `swiftpm-testing-helper` at PID `87803` was written to
  `tmp/wikifs-app-tests-hang.sample.txt`
- the sample showed the main thread idle in `CFRunLoopRun` /
  `mach_msg2_trap`; background Tantivy `segment_updater`, `merge_thread_*`,
  and `thread-tantivy-meta-file-watcher` threads were sleeping or opening
  files; no assertion failure or Phase 5 chat stack was active in the sample
- the stuck worktree-owned processes were terminated with
  `kill 87803 86045`

This is recorded as a local-environment app-hosted full-suite teardown hang,
not an unresolved Phase 5 architecture, concurrency, or repeated-failure
judgment. The required app-hosted evidence for the Phase 5 chat UI surface is
the focused `WIKIFS_APP_TESTS=1` chat suite pass above.
