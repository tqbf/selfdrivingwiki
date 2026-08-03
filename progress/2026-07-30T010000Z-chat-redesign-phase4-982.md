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

Local date note: the UTC timestamp `2026-07-30T010000Z` corresponds to
Wednesday, July 29, 2026 PDT in America/Los_Angeles.

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

## Exact-head corrective files changed

Production:

- `Sources/WikiFSEngine/ChatSyncWire.swift`
- `Sources/WikiFSEngine/ChatClientSync.swift`
- `Sources/WikiFS/Queue/DaemonQueueEventSink.swift`
- `Sources/WikiFS/Chats/RemoteChatSession.swift`
- `Sources/WikiFS/Chats/ChatDaemonCoordinator.swift`
- `Sources/WikiFS/Chats/ChatDetailView.swift`
- `Sources/wikid/DaemonChatController.swift`
- `Sources/wikid/WikiDaemon.swift`

Tests:

- `Tests/WikiFSTests/ChatClientSyncReducerTests.swift`
- `Tests/WikiFSTests/ChatSyncWireTests.swift`
- `Tests/WikiFSAppTests/RemoteChatSessionTests.swift`
- `Tests/WikiFSAppTests/DaemonChatHostTests.swift`

Documentation:

- `plans/chat-architecture-redesign.md`
- `progress/2026-07-30T010000Z-chat-redesign-phase4-982.md`

## Exact-head audit repairs

The exact-head corrective pass on top of head
`6a956b6d09bc8c0c33e5fcbd509154141ff65d21` repaired these audit findings
inside Phase 4 scope:

- `C-1` terminal transcript convergence now preserves the last streamed
  assistant/reasoning overlay through `.completed`, `.failed`, and
  `.cancelled` until authoritative committed history actually catches up.
  The reducer keeps typed identity deduplication, so a committed replacement
  still displaces the overlay once the final persisted row is reloaded.
- `H-1` the hot chat-sync path is now bounded in two places:
  `ChatSyncUpdateEnvelope` compacts transcript updates by omitting the
  accumulated overlay when the reason already carries the transcript delta, and
  the app decodes `ChatSyncUpdate` once at `DaemonQueueEventSink` before
  routing the typed value through `ChatDaemonCoordinator` to
  `RemoteChatSession`. The direct wire regression asserts the compact envelope
  is smaller than the former full-projection encoding for the same streamed
  transcript.
- `H-2` optimistic rollback is now provenance-aware. Once an authoritative
  active turn, queued turn, or committed user row exists for a turn, the
  reducer discards the optimistic lifecycle backup for that turn, so a later
  submit failure cannot revert the daemon-owned ready/queued state or delete
  the durable user message.
- `M-4` committed-history paging tasks are now tracked and canceled on
  `RemoteChatSession.reset()`. The loader checks cancellation before applying a
  returned page, so a stale paging task cannot write transcript rows into a
  fresh draft/chat session after reset.
- `L-1` `WikiDaemon.chatSessionStateData` now logs snapshot-read failures
  before returning the compatibility empty payload.
- `L-2` `ChatDetailView` now uses `RemoteChatSession.committedHistoryPageSize`
  instead of a duplicate bare `200`.
- `L-4` `DaemonChatController.syncProjection()` is now nonthrowing and the dead
  `try`/`catch` branches around compatibility refresh and sync-update emission
  are removed.
- `L-7` the XPC missing-chat assertion now checks the actual empty-payload
  contract instead of the tautology `count <= 1 || isEmpty`.

## Regression coverage added or updated

New or expanded focused suites:

- `ChatSyncWireTests`
- `ChatClientSyncReducerTests`

Updated app-facing suites:

- `RemoteChatSessionTests`
- `ChatDaemonCoordinatorTests`
- `DaemonChatControllerTests`
- `DaemonChatHostTests`

The most important direct assertions at the repaired head are:

- DTO round trips for typed snapshot/update envelopes
- compact transcript update envelopes are smaller than the old
  accumulated-overlay encoding
- malformed/missing/unsupported wire-version rejection
- successive multi-page committed-history paging using advancing cursors
- duplicate update suppression
- stale generation rejection
- missing-sequence gap detection followed by authoritative snapshot request
- bounded retry after authoritative snapshot failure
- compact transcript updates rebuild the full display overlay from the carried
  transcript delta
- reconnect snapshot hydration without losing already loaded committed history
- optimistic submit visibility, duplicate suppression, and
  authoritative-lifecycle-preserving rollback
- terminal `.completed`, `.failed`, and `.cancelled` updates keep the longer
  streamed overlay visible until committed history catches up
- overlay/history reconciliation when committed transcript rows arrive
- duplicate committed user rows for one turn do not trap during reconciliation
- reset cancels a pending history load before a stale page can apply to the
  fresh session
- permission compatibility mapping and terminal-outcome cleanup
- persisted-only `chatSessionState` performs at most one interrupted-turn
  recovery write, then stabilizes on repeated reads
- real daemon/client request-response adapter coverage, including strictly
  consecutive sync-update sequences and compatibility refresh suppression

## Explicit dispositions

The corrective pass intentionally left these items re-parked with named
follow-up phases instead of pretending they were fixed in Phase 4:

- `M-1` model-side desynchronization status remains exposed at
  `RemoteChatSession.syncStatus` / `syncState?.syncStatus`. Rendering a
  dedicated out-of-sync banner or retry affordance in `ChatDetailView` is
  re-parked to `Phase 5` UI decomposition because this pass keeps the current
  rendering surface stable.
- `M-2` `DaemonChatHost.persistedOnlySessionState` still performs the
  interrupted-turn recovery write through `bootstrapSnapshot` on the first
  persisted-only read. That architecture split is re-parked to `Phase 6`
  compatibility cleanup, but the bounded current contract is now pinned by
  `persistedOnlyChatSessionStateReadPerformsOneBoundedRecoveryWriteThenStabilizes`.
- `M-3` `WikiStoreModel.readChatTranscriptPage` still collapses store read
  failures to an empty page. Re-parked to `Phase 6` compatibility/error-surface
  cleanup because fixing it cleanly requires changing the current app-facing
  nonthrowing model adapter contract.
- `L-3` compatibility `exitStatus` remains `nil`. Re-parked to `Phase 6`
  compatibility cleanup because reducer-owned daemon lifecycle is now
  authoritative and `exitStatus` is a launcher-era surface without a typed
  daemon equivalent.
- `L-8` the dead legacy `DaemonChatHost` launcher/session path and its
  unreachable envelope emitters remain in the tree. This pass does not claim
  they were removed; their deletion stays re-parked to `Phase 6`
  daemon-host/compatibility cleanup so the corrective pass stays focused on
  Phase 4 sync correctness.

## Verification

Verified locally on Wednesday, July 29, 2026 (America/Los_Angeles):

- `make prompts`
  - passed
- `swift test --filter ChatSyncWireTests`
  - passed: `8 tests in 1 suite`
- `swift test --filter ChatClientSyncReducerTests`
  - passed: `18 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter 'RemoteChatSessionTests|ChatDaemonCoordinatorTests|DaemonChatControllerTests|DaemonChatHostTests'`
  - passed: `62 tests in 4 suites`
- `make build`
  - passed
  - built signed app bundle: `build/Self Driving Wiki.app`
- `make test`
  - passed: `2695 tests in 218 suites`
- `WIKIFS_APP_TESTS=1 swift test`
  - local blocker, not counted as a pass
  - the hosted umbrella run reached app-hosted suites and stayed alive for more
    than eleven minutes under `swiftpm-testing-helper`, but stopped producing
    test output and did not terminate cleanly
  - an explicit sample of the still-live helper at local timestamp
    `2026-07-29 21:00:45 -0700` showed the main thread idle in
    `CFRunLoopRun`/`mach_msg` rather than actively executing test work
  - this entry does not claim the hung local umbrella run as a pass; exact-SHA
    CI checks after push are the repository-authorized hosted verification for
    this branch head

## Scope audit

Diff against the merged Phase 3 `main` head
`e992148314283807ac1066a1d6c223533631d053` stayed inside Phase 4:

- transport and daemon call sites still use JSON-encoded `Data`
- client-side churn is concentrated in `RemoteChatSession` and
  `ChatDaemonCoordinator` reducer/hydration wiring
- `ChatDetailView` changes are limited to hydration-task identity, committed
  history loading, and optimistic submit rollback; no broad UI decomposition or
  child-view extraction landed
