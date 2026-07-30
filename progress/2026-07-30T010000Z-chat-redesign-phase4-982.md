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

Local date note: the timestamp `2026-07-30T010000Z` is Wednesday, July 29,
2026 in America/Los_Angeles.

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

## Exact-head audit repairs

The corrective pass on top of head `6a956b6d09bc8c0c33e5fcbd509154141ff65d21`
repaired these exact Opus audit findings inside Phase 4 scope:

- `C-1` committed-history paging now advances with `nextCursor` / last loaded
  cursor instead of the table-wide checkpoint watermark, and multi-page
  history loading is pinned by a direct `>= 2` page regression.
- `H-1` optimistic-submit rollback now preserves the authoritative lifecycle
  instead of synthesizing `.closed` when the optimistic overlay clears.
- `H-2` controller sync pushes now reuse a cached committed cursor, ignore
  compatibility-only `lastActivityAt` churn, trim transient overlay at
  terminal outcomes, and no longer emit the dead legacy `chatEvent` envelope.
- `H-3` authoritative snapshot reload now retries with bounded backoff after a
  gap-triggered snapshot failure and re-arms from hydration.
- `H-4` committed/live reconciliation no longer uses
  `Dictionary(uniqueKeysWithValues:)` on coarse turn identity; duplicate
  committed user rows for one turn no longer trap on the main actor.
- `M-1` the daemon no longer emits legacy `.chatEvent` traffic that the queue
  sink rejects.
- `M-2` persisted-only baselines now accept the first live generation update
  instead of forcing an unnecessary snapshot round trip.
- `M-5` real controller coverage now proves strictly consecutive sync-update
  sequences and that compatibility refreshes which only move `lastActivityAt`
  do not bump sequence.
- `L-7` and `L-8` documentation dates and coverage claims were corrected to
  match America/Los_Angeles local time and the actual test matrix at this
  head.
- `L-9` the terminal-outcome reducer test now asserts the stronger behavior its
  name describes.

## Regression coverage added or updated

New or expanded focused suites:

- `ChatSyncWireTests`
- `ChatClientSyncReducerTests`

Updated app-facing suites:

- `RemoteChatSessionTests`
- `ChatDaemonCoordinatorTests`
- `DaemonChatHostTests`

The most important direct assertions at the repaired head are:

- DTO round trips for typed snapshot/update envelopes
- malformed/missing/unsupported wire-version rejection
- successive multi-page committed-history paging using advancing cursors
- duplicate update suppression
- stale generation rejection
- missing-sequence gap detection followed by authoritative snapshot request
- bounded retry after authoritative snapshot failure
- reconnect snapshot hydration without losing already loaded committed history
- optimistic submit visibility, duplicate suppression, and lifecycle-preserving
  rollback
- overlay/history reconciliation when committed transcript rows arrive
- duplicate committed user rows for one turn do not trap during reconciliation
- permission compatibility mapping and terminal-outcome cleanup
- real daemon/client request-response adapter coverage, including strictly
  consecutive sync-update sequences and compatibility refresh suppression

## Verification

## Explicit dispositions

The corrective pass intentionally left these items re-parked with named
follow-up phases instead of pretending they were fixed in Phase 4:

- `M-3` `WikiStoreModel.readChatTranscriptPage` still collapses store read
  failures to an empty page. Re-parked to `Phase 6` compatibility/error-surface
  cleanup because fixing it cleanly requires changing the current app-facing
  nonthrowing model adapter contract.
- `M-4` `WikiDaemon.chatSessionStateData` still returns empty `Data()` on
  daemon-side snapshot failure. Re-parked to `Phase 6`
  compatibility/error-envelope cleanup because the current XPC contract still
  carries raw `Data` rather than a typed failure envelope.
- `M-6` the `DaemonChatHost` actor registry still uses synchronous queue hops.
  Re-parked to `Phase 6` daemon-host cleanup because Phase 4 synchronization
  correctness did not require changing registry ownership or host lifetime.
- `M-7` controller idle eviction remains deferred to `Phase 6` daemon-host
  cleanup for the same reason: it is controller-lifetime policy, not a Phase 4
  wire/reducer correctness issue.
- `M-8` daemon-host wiki resolution / partial-error cleanup remains re-parked
  to `Phase 6` daemon-host cleanup because it lives in host bootstrap and
  registry mapping, not in the repaired sync wire.
- `M-9` remaining launcher-era helpers and debug seams stay re-parked to
  `Phase 6` compatibility cleanup. This pass removed only the proved-dead
  legacy `chatEvent` push.
- `M-10` `ChatDetailView` follow-up queue ownership remains explicitly deferred
  to `Phase 5` UI decomposition and was not implemented here.
- `L-1` / `L-2` `ChatSyncWire` constant deduplication and symmetric decode
  error cleanup are re-parked to `Phase 6` compatibility cleanup because the
  wire behavior is already pinned by direct decode tests and no protocol
  behavior changes were required for this corrective head.
- `L-3` the draft callback wiring remains a no-op and is re-parked to
  `Phase 5` UI decomposition because the coordinator still reuses one session
  construction path for draft and persisted sessions; current no-op behavior is
  pinned by `draftSessionDoesNotWireConfigCallback`.
- `L-4` `RemoteChatSession` now owns the paging constant, but
  `ChatDetailView` still passes a bare `200`. Final UI-surface dedup is
  re-parked to `Phase 5` UI decomposition.
- `L-5` compatibility `exitStatus` remains `nil`. Re-parked to `Phase 6`
  compatibility cleanup because reducer-owned daemon lifecycle is now
  authoritative and `exitStatus` is a launcher-era surface without a typed
  daemon equivalent.
- `L-6` `DaemonChatHost.hasLiveSession` remains dead surface and is re-parked
  to `Phase 6` daemon-host cleanup.

## Verification

Verified locally on Wednesday, July 29, 2026 (America/Los_Angeles):

- `make prompts`
  - passed
- `swift test --filter ChatSyncWireTests`
  - passed: `7 tests in 1 suite`
- `swift test --filter ChatClientSyncReducerTests`
  - passed: `13 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter RemoteChatSessionTests`
  - passed: `12 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter ChatDaemonCoordinatorTests`
  - passed: `10 tests in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter DaemonChatControllerTests`
  - passed: `18 tests in 1 suite`
- `make build`
  - passed
  - built signed app bundle: `build/Self Driving Wiki.app`
- `make test`
  - passed: `2689 tests in 218 suites`
- `WIKIFS_APP_TESTS=1 swift test`
  - local blocker: bounded run timed out after `240` seconds
  - the hosted umbrella run advanced well into later UI suites, including
    `PageDetailViewHostedTests`, `AddressBarLayoutHostedTests`, and
    `ComposerAutocompleteHostedTests`, but the command did not terminate within
    the bounded window on this machine

## Scope audit

Diff against the merged Phase 3 `main` head
`e992148314283807ac1066a1d6c223533631d053` stayed inside Phase 4:

- transport and daemon call sites still use JSON-encoded `Data`
- client-side churn is concentrated in `RemoteChatSession` and
  `ChatDaemonCoordinator` reducer/hydration wiring
- `ChatDetailView` changes are limited to hydration-task identity, committed
  history loading, and optimistic submit rollback; no broad UI decomposition or
  child-view extraction landed

## Final verification note

- The repository-required `WIKIFS_APP_TESTS=1 swift test` umbrella hosted run
  was rerun from fresh local state under a `240`-second wrapper and timed out
  rather than terminating cleanly. This entry records that command as a local
  hosted-suite blocker, distinct from the focused Phase 4 suites and the
  repository-wide `make test` pass that completed successfully.
