---
timestamp: 2026-07-30T010000Z
title: Chat redesign Phase 4 implementation for issue #982
branch: chat-redesign-phase4-xpc-sync
status: complete
---

# Chat redesign Phase 4 implementation for issue #982

## Progress

This entry records the Phase 4 implementation pass on branch
`chat-redesign-phase4-xpc-sync` after the branch was corrected to the merged
Phase 3 `main` head `e992148314283807ac1066a1d6c223533631d053`.

Scope stayed inside Phase 4:

- replaced the launcher-shaped chat XPC mirror with versioned sequenced
  snapshot/update DTOs while preserving JSON-encoded `Data` transport
- added explicit wire-version validation/rejection at the transport boundary
  instead of silently accepting unknown chat payload versions
- moved client synchronization into a pure reducer-owned store/projection and
  kept `RemoteChatSession` only as a compatibility adapter
- wired authoritative snapshot catch-up, optimistic submit, gap recovery, live
  overlay reconciliation, and durable-history preservation through the real
  daemon/client path
- updated plan/progress evidence and kept Phase 5 UI decomposition out of
  scope

Out of scope and still deferred:

- Phase 5 `ChatDetailView` decomposition and follow-up queue ownership cleanup
- broader compatibility-layer deletion beyond the narrow adapter needed for the
  current rendering surface

## Shipped behavior

The Phase 4 head adds these production contracts:

- `P4-1` `chatSessionState` still crosses XPC as `Data`, but that data now
  encodes `ChatSyncSnapshotEnvelope` and rejects missing/unsupported wire
  versions explicitly.
- `P4-2` queue-delivered chat state now uses `ChatSyncUpdateEnvelope`, and the
  app rejects legacy chat mirror payload kinds instead of interpreting them as
  current state.
- `P4-3` the client projection is reducer-owned. `ChatClientSyncReducer`
  applies authoritative snapshots and sequenced deltas, ignores duplicates,
  rejects stale generations/turns, requests snapshot recovery on gaps, and
  preserves already loaded committed history until authoritative catch-up
  arrives.
- `P4-4` reconnect/hydration uses an authoritative snapshot plus committed
  history paging instead of replacing known history with a live tail.
- `P4-5` optimistic submit is visible immediately in the compatibility surface
  but deduplicates repeated submission attempts and reconciles back to durable
  history when the committed transcript arrives.
- `P4-6` live overlay and committed history now reconcile by transcript
  identity so durable rows replace matching optimistic/live items without
  deleting unrelated history.
- `P4-7` `ChatDetailView` keeps its current rendering behavior and typed
  submit/permission/cancel path; the branch does not claim the later Phase 5 UI
  decomposition.

## Production files changed

- `Sources/WikiFSEngine/ChatSyncWire.swift`
- `Sources/WikiFSEngine/ChatClientSync.swift`
- `Sources/WikiFSEngine/QueueEventEnvelope.swift`
- `Sources/WikiCtlCore/DaemonWorkloadClient.swift`
- `Sources/WikiDaemonContract/WikiDaemonProtocol.swift`
- `Sources/wikid/WikiDaemon.swift`
- `Sources/wikid/DaemonChatHost.swift`
- `Sources/wikid/DaemonChatController.swift`
- `Sources/wikid/LauncherChatAgentRuntime.swift`
- `Sources/WikiFSCore/Store/WikiStoreModel.swift`
- `Sources/WikiFS/Queue/DaemonQueueEventSink.swift`
- `Sources/WikiFS/Chats/RemoteChatSession.swift`
- `Sources/WikiFS/Chats/ChatDaemonCoordinator.swift`
- `Sources/WikiFS/Chats/ChatDetailView.swift`

## Regression coverage added or updated

New focused suites:

- `ChatSyncWireTests`
- `ChatClientSyncReducerTests`

Updated app-facing suites:

- `RemoteChatSessionTests`
- `ChatDaemonCoordinatorTests`
- `DaemonChatHostTests`

The most important direct assertions are:

- DTO round trips for typed snapshot/update envelopes
- malformed/missing/unsupported wire-version rejection
- duplicate update suppression
- stale generation rejection
- missing-sequence gap detection followed by authoritative snapshot request
- reconnect snapshot hydration without losing already loaded committed history
- optimistic submit visibility and duplicate suppression
- overlay/history reconciliation when committed transcript rows arrive
- permission compatibility mapping and terminal-outcome cleanup
- real daemon/client request-response adapter coverage, not only isolated value
  types

## Verification

Verified locally on Thursday, July 30, 2026:

- `make prompts`
  - passed
- `swift test --filter ChatSyncWireTests`
  - passed: `7 tests in 1 suite`
- `swift test --filter ChatClientSyncReducerTests`
  - passed: `10 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter RemoteChatSessionTests`
  - passed: `10 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter ChatDaemonCoordinatorTests`
  - passed: `9 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter DaemonChatHostTests`
  - passed: `20 tests in 1 suite`
- `make build`
  - passed
  - built signed app bundle: `build/Self Driving Wiki.app`
- `make test`
  - passed: `2686 tests in 218 suites`
- `WIKIFS_APP_TESTS=1 swift test`
  - did not terminate cleanly on this machine
  - after more than four minutes, the helper process
    `swiftpm-testing-helper` remained alive at `0.0%` CPU in the hosted-suite
    tail (`PID 63295` at the time of inspection)
  - this entry records that command as a local verification blocker rather than
    a passing result

## Scope audit

Diff against the merged Phase 3 `main` head
`e992148314283807ac1066a1d6c223533631d053` stayed inside Phase 4:

- transport and daemon call sites still use JSON-encoded `Data`
- client-side churn is concentrated in `RemoteChatSession` and
  `ChatDaemonCoordinator` reducer/hydration wiring
- `ChatDetailView` changes are limited to hydration-task identity, committed
  history loading, and optimistic submit rollback; no broad UI decomposition or
  child-view extraction landed

## Blockers / waivers

- The repository-required `WIKIFS_APP_TESTS=1 swift test` command remains a
  local hang on this machine. Focused app-target suites covering the Phase 4
  reducer/wire path passed, but the umbrella hosted run is recorded as a local
  blocker rather than waived away.
