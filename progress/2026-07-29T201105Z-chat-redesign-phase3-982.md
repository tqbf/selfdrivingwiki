---
timestamp: 2026-07-29T201105Z
title: Chat redesign Phase 3 corrective implementation for PR #990 / issue #982
branch: chat-redesign-phase3
status: complete
---

# Chat redesign Phase 3 corrective implementation for PR #990 / issue #982

## Scope

This entry records the corrective implementation pass for the exact audited PR
head `ea29a810d946a2b082b80e0b430704d092f51fc4` on branch
`chat-redesign-phase3`.

Scope stayed inside Phase 3:

- repaired daemon/runtime/controller/store contracts that regressed transcript
  persistence, live streaming, resume fallback, preflight handling, queue
  draining, and shared generation-gate wiring
- added production-shaped regression coverage at the runtime-translation seam
  and the controller/store persistence seam
- corrected the chat API signature manifest and the Phase 3 progress/plan/PR
  documentation

Out of scope and still deferred:

- Phase 4 XPC wire redesign
- Phase 4 pure client reducer migration
- Phase 5 `ChatDetailView` decomposition / follow-up queue ownership

## Corrected production behavior

The repaired head fixes the audit-blocking Phase 3 contracts:

- `C-1` Assistant and reasoning output now persist again. Raw
  `.assistantTextDelta` / `.thinkingDelta` sequences are coalesced into stable
  `messageReplacement` items with deterministic `ChatMessageID`s, and the
  controller/store seam now persists those replacements instead of dropping
  them.
- `C-2` Live assistant/reasoning deltas are forwarded to the app again. The
  runtime now forwards live events independently from persistence filtering, so
  `RemoteChatSession` receives streaming envelopes while durable history remains
  authoritative.
- `C-3` Cold-start / resume-failure fallback now restores bounded continuation
  context. When no provider session exists, the runtime sends a bounded
  continuation preamble built from persisted history while keeping the visible
  user message equal to the new submission text.
- `H-1` One shared daemon generation gate is threaded back through
  `WikiDaemon -> DaemonChatHost -> LauncherChatAgentRuntime -> AgentLauncher`.
- `H-2` Hard preflight failures propagate again from the runtime/controller path
  and new-chat submit rolls back the just-created chat row instead of leaving an
  orphan chat.
- `H-3` Failed turns and transport-close recovery now advance the durable queue
  so followers already enqueued before the failure are submitted automatically.
- `H-4` `chatSessionState(chatID:)` no longer constructs controllers or clears
  stored provider session ids on a read path; persisted-only rehydration is a
  pure store read when no controller exists.
- `H-5` Per-message/per-chat summarization is wired again through the runtime's
  `onMessageSummary` callback into the daemon host summarization path.

Additional corrective work landed with the same pass:

- `.sessionReady` no longer clobbers a newly observed provider session id
  (`M-1`)
- provider-session snapshot updates now flow through recorded updates instead of
  direct snapshot mutation (`M-2`)
- duplicate bootstrap `.queued` records are suppressed (`M-3`)
- fast permission requests are accepted while the active turn is still in
  `.submitting` and `.started` is recorded before runtime submission (`M-6`)
- preflight errors are checked before the transport-close polling path can mask
  them (`M-7`)
- tool-call rows now converge by transcript identity and preserve tool names
  from use -> result (`M-8`)
- daemon-side empty-message validation is restored at the typed submit boundary
  (`L-8`)
- controller-harness temp directories are removed in test teardown (`L-7`)

## Regression coverage added or updated

The corrective pass added or tightened these direct regression tests:

- `LauncherChatAgentRuntimeTests.transcriptTranslationCoalescesAssistantAndReasoningDeltasIntoStableMessageReplacements`
- `LauncherChatAgentRuntimeTests.transcriptTranslationPreservesToolIdentityAcrossUseAndResult`
- `DaemonChatControllerTests.productionTranslatedDeltasPersistAssistantReasoningAndToolRowsWithoutDuplicates`
- `DaemonChatControllerTests.restartRecoveryMarksClaimedTurnInterruptedAndPreservesProviderSessionForResumeFallback`
- `DaemonChatHostTests.daemonChatHostUsesSharedGenerationGate`
- `DaemonChatHostTests.newChatPreflightFailureRollsBackCreatedRowAndPropagatesError`
- `DaemonChatHostTests.existingChatPreflightFailurePreservesRowAndPropagatesError`
- `Tests/WikiFSTests/Fixtures/ChatAPISignatures.txt` now includes the newly
  exposed Phase 3 `ChatID` surfaces in the daemon/store/XPC/coordinator layer

The most important new end-to-end coverage is the production-shaped ACP delta
path:

- raw assistant/reasoning/tool events are translated by
  `LauncherChatAgentRuntime.transcriptDeltasForTesting(...)`
- those translated deltas are then driven through the real
  `DaemonChatController` persistence seam
- tests assert both the client-visible stable transcript items and the durable
  `chat_messages` / transcript-row results

## Medium / low dispositions

Every non-blocking audit item is either repaired above or explicitly carried as
an intentional Phase 3 disposition:

- `M-4` Partially improved, not fully redesigned. `DaemonChatHost.makeOrGetController`
  no longer performs controller bootstrap construction under the registry lock,
  but the registry still uses a `DispatchQueue.sync` gate. A full actor-based
  registry remains a Phase 4 architectural cleanup, not a corrective Phase 3
  contract fix.
- `M-5` Not fully repaired in this pass. The daemon intentionally retains
  per-chat controllers for process lifetime in Phase 3 and still has no idle
  eviction policy. This is a bounded daemon-lifetime retention issue rather than
  an acceptance-criteria blocker; follow-up cleanup should remove the remaining
  launcher-era registry baggage together with Phase 4/5 lifecycle reshaping.
- `M-9` Partially improved. `resolveWikiID(for:)` now logs non-benign resolver
  failures instead of swallowing them silently, but it still scans known wikis.
  A durable `ChatID -> WikiID` index is deferred because it would expand the
  persistence model beyond this corrective pass.
- `L-1` Fixed. Replay capacity is named via `Self.replayCapacity`.
- `L-2` Partially deferred. Internal dead launcher-era helpers remain in
  `DaemonChatHost`; they are unused but not load-bearing. Removing them was kept
  out of this corrective pass to avoid mixing structural cleanup with the
  audited contract repairs.
- `L-3` Deferred. `startInteractiveQuery`'s optional callback semantics are
  unchanged for current callers; no Phase 3 behavior depends on restoring the
  older default wiring shape.
- `L-4` Deferred. The temporary `chatLive` seam-1 diagnostic remains debug-only
  instrumentation and is not part of the production contract.
- `L-5` Documented by current controller tests. Pending cancellation without a
  live runtime is still treated as at-most-once terminal intent for the active
  turn; no contradictory winner path is exercised on the repaired head.
- `L-6` Intentional at-most-once policy. Post-claim submission failures remain
  terminal failures rather than automatic requeue; this corrective pass keeps
  that policy explicit instead of reintroducing duplicate-submission risk.
- `L-9` Deferred to Phase 5. `ChatDetailView` still owns the in-memory follow-up
  queue and UI send gating, so this branch does not claim full end-to-end AC.4
  UI-producer coverage.
- `L-10` Fixed by this progress entry, the matching plan note, and the updated
  PR body.

## Verification

Verified locally on Wednesday, July 29, 2026:

- `make prompts`
- `make build`
- `make test`
  - passed: `2669 tests in 216 suites`
- `swift test --filter ChatAPISignatureManifestTests`
  - passed: `1 test in 1 suite`
- `WIKIFS_APP_TESTS=1 swift test --filter 'DaemonChatHostTests|DaemonChatControllerTests|LauncherChatAgentRuntimeTests'`
  - passed: `36 tests in 3 suites`
- `WIKIFS_APP_TESTS=1 swift test --filter 'LauncherChatAgentRuntimeTests|DaemonChatControllerTests|DaemonChatHostTests|ChatDaemonCoordinatorTests|RemoteChatSessionTests|WikiDaemonConnectionHealthTests'`
  - passed: `100 tests in 6 suites`
- `WIKIFS_APP_TESTS=1 swift test`
  - rerun during the corrective pass to refresh the hosted-suite evidence for
    this repaired head; the matching PR body records the exact local outcome for
    the pushed commit

## Files changed in the corrective pass

- `Sources/wikid/LauncherChatAgentRuntime.swift`
- `Sources/wikid/DaemonChatController.swift`
- `Sources/wikid/DaemonChatHost.swift`
- `Sources/wikid/WikiDaemon.swift`
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift`
- `Sources/WikiFSEngine/ChatDomain.swift`
- `Tests/WikiFSAppTests/LauncherChatAgentRuntimeTests.swift`
- `Tests/WikiFSAppTests/DaemonChatControllerTests.swift`
- `Tests/WikiFSAppTests/DaemonChatHostTests.swift`
- `Tests/WikiFSTests/Fixtures/ChatAPISignatures.txt`
