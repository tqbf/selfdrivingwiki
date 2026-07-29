---
timestamp: 2026-07-29T074900Z
title: "2026-07-29 — Chat domain foundation Phase 0/1 (#982)"
branch: chat-domain-audit-fixes
status: blocked
---

# 2026-07-29 — Chat domain foundation Phase 0/1 (#982)

## Progress

**Scope.** This branch still lands only the foundation slice of the reviewed
chat architecture redesign for issue #982. It intentionally stops before schema
v46, durable turn persistence, daemon controller replacement, XPC migration,
client synchronization, and UI decomposition.

**What landed.**
- Added the design record at
  [`plans/chat-architecture-redesign.md`](../plans/chat-architecture-redesign.md)
  and linked it from [`PLAN.md`](../PLAN.md).
- Added Foundation-only chat domain identifiers in `WikiFSTypes`:
  `ChatTurnID`, `ChatMessageID`, `ChatCommandID`,
  `ChatSessionGenerationID`, `ChatUpdateSequence`,
  `PermissionRequestID`, `PermissionOptionID`, and moved `ToolCallID`
  into `WikiFSTypes` without changing raw boundary formats.
- Added `ChatContextReference`, `ChatTurnSubmission`, and the shared
  Foundation-only `ChatTranscriptItem` vocabulary in
  `Sources/WikiFSTypes/ChatConversationTypes.swift`.
- Added the Phase 1 engine-side value domain in
  `Sources/WikiFSEngine/ChatDomain.swift`, including orthogonal session,
  turn, attention, capability, permission, snapshot, update, and replay-buffer
  types plus a pure session state-machine reducer.
- Added `Sources/WikiFSEngine/ChatTranscriptReducer.swift` so live transcript
  updates, replay, and tests share one typed reducer instead of ad hoc folds.
- Added `Sources/WikiFSEngine/ChatAgentRuntime.swift` with the typed
  `ChatAgentRuntime` protocol, event envelope, start/configuration requests,
  and a closure-backed runtime seam that characterizes the current
  launcher/backend boundary without yet replacing it. The original Phase 0
  production `AgentLauncher`/ACP adapter remains explicitly deferred rather
  than silently dropped; the protocol seam is what this branch lands.
- Added `ScriptedChatRuntime` test support with deterministic pause gates,
  generation-preserving event envelopes, and sleep-free teardown behavior. The
  gate implementation was corrected to use stored permits so a resume cannot be
  lost if it arrives before the drain task parks.
- Defined and landed the corrective closed-session queue policy in
  `ChatSessionMachine`: `sessionClosed` now clears only active execution state
  and attention, preserves queued turns, and `sessionReady` re-promotes the
  oldest queued turn back to active `.queued` state so recovery does not strand
  user-submitted follow-ups.
- Added Phase 0/1 guardrails and corrective audit coverage:
  `ChatIdentifierCodableCompatibilityTests`,
  `ChatDomainStateTests`,
  `ChatDomainAuditRegressionTests`,
  `ChatTranscriptReducerTests`,
  `ScriptedChatRuntimeTests`,
  `ChatAgentRuntimeCoverageTests`,
  `ChatDomainAPISignatureManifestTests`,
  and new `IdentifierBoundaryTypecheckTests` fixtures for turn, message,
  command, and permission/tool-call namespace boundaries.
- Repaired the typed `ProviderID`/`ModelID` app-test fixture drift that blocked
  the earlier corrective audit from even compiling the opt-in app test target.
- Repaired the hosted `PageDetailView` test harness so it injects the
  `WindowRightInspectorController` environment object the live app provides,
  without papering over real environment failures.
- Corrected the bookmarks single-leaf edit behavior and tests so leaf
  references expose the intended `Edit…` affordance, and the app test asserts
  the exact Unicode ellipsis title.
- Extended the bookmark edit flow into a public leaf-retarget feature:
  `EditBookmarkSheet` now retargets page/source/chat bookmarks, keeps the sheet
  open on validation failure, and surfaces the typed store error instead of
  silently dismissing.
- Finished the remaining exact-head audit follow-up in-scope for this
  foundation PR:
  `ChatDomainAuditRegressionTests` now asserts typed rejection results for the
  missing AC.3 negative cases (duplicate terminal events, stale turn-ID
  mismatches including permission requests, illegal permission resolution, and
  illegal lifecycle edges for `sessionClosed`, `sessionReady`, and
  `recovering`), and the folder-rename path now matches bookmark retargeting by
  propagating the store error back to `EditBookmarkSheet` instead of logging and
  dismissing.

**Important compatibility decisions preserved.**
- Raw identifier text stayed primitive-string-compatible at JSON and Codable
  boundaries.
- `AcpSessionID` remains the provider-session namespace; no duplicate wrapper
  was introduced.
- The new transcript vocabulary is Foundation-only and does not pull Engine or
  Core dependencies into `WikiFSTypes`.
- The snapshot model still carries the Phase 1 deferral for a
  committed-transcript cursor. This branch models only the transient overlay
  plus `lastIncludedSequence`; durable cursoring remains a later
  persistence/client-sync concern.
- The typecheck guard stays compiler-level, not runtime-only: the
  `IdentifierBoundaryTypecheckTests` fixtures still run `swiftc -typecheck`
  against the built modules, with a host-target triple that supports both macOS
  and Linux compilation paths even though the current CI/test evidence in this
  branch is macOS-only.
- No schema migration, chat-row compatibility decoder, or UI migration landed
  in this branch.
- `WikiDaemonConnection.healthCheck(timeout:)` keeps the branch's bounded
  detached-timeout race instead of the earlier task-group shape because the XPC
  send path can hang indefinitely when the mach service is absent. The
  rationale stays documented inline in
  [`Sources/WikiCtlCore/WikiDaemonConnection.swift`](../Sources/WikiCtlCore/WikiDaemonConnection.swift).
- `ChatAgentRuntime.eventStream(for:)` is intentionally `async throws` in the
  Phase 0 protocol seam so production and scripted runtimes can reject unknown
  handles and duplicate subscribers through the same typed contract; that
  widening is covered by `ChatAgentRuntimeCoverageTests` and
  `ScriptedChatRuntimeTests`.
- This corrective branch also tightens the public bookmark retarget mutation in
  `GRDBWikiStore`: retargeting now validates page/source/chat targets inside
  the same write transaction so typed bookmark references cannot be rewritten
  to dangling rows.

**Audit disposition on Wednesday, July 29, 2026.**
- **F1 (missing explicit negative state-machine rejection coverage): fixed.**
  `ChatDomainAuditRegressionTests` now parameterizes the previously-missing
  AC.3 rejection matrix and asserts the exact
  `.rejected(.illegalTransition(payload: ...))` result for duplicate terminal
  events, stale turn mismatches, wrong permission resolutions, and illegal
  lifecycle edges.
- **F2 (`transcriptChanged` active-turn guard): explicitly rebutted / deferred.**
  The reducer still accepts `transcriptChanged` without an active-turn guard.
  That remains the intentional Phase 3 controller-ordering responsibility from
  the design record rather than a Phase 0/1 reducer bug, so this branch does
  not add a premature guard.
- **F3 (folder rename error handling mismatch): fixed.**
  `WikiStoreModel.renameBookmarkNode` is now throwable like
  `retargetBookmarkNode`, and `EditBookmarkSheet` keeps the folder-edit sheet
  open and renders the localized store error instead of silently dismissing.
- **F4 (stale-target picker UX): explicitly deferred.**
  A deleted target can still leave `EditBookmarkSheet` with a preselected value
  that no longer exists in the current picker options. The transactional store
  rejection remains the authoritative guard, and this branch deliberately keeps
  that stale-data presentation quirk out of the Phase 0/1 foundation scope.

## Verification

- Wednesday, July 29, 2026:
  `make prompts` — passed.
- Wednesday, July 29, 2026:
  `make build` — passed, including app assembly/signing and MLX runtime
  bundling.
- Wednesday, July 29, 2026:
  `make test` — passed with `2653 tests in 215 suites`.
- Wednesday, July 29, 2026:
  `env WIKIFS_APP_TESTS=1 TEST_TIMEOUT=60 make test-watchdog` — timed out with
  wrapper exit `124` (reported as `TIMED OUT after 60s` and `Exiting 124`
  after reaping `swift test`).
  Log: `tmp/test-logs/swift-test-20260729-100115.log`.
- The timeout probe is materially better than the inherited raw `swift test`
  hang note because it uses the repo-owned watchdog target, reaps orphaned
  `swiftpm-testing-helper` children, records a stable log path, and reports the
  started-but-never-finished test set from that exact run. On this head that
  set included hosted/app-layer and parameterized suites such as
  `PageAuthor round-trips every case through rawValue`,
  `SourceProvider round-trips every case through rawValue`,
  `Byteless YouTube WITH transcript is enqueued (C5 — transcript seeded)`, and
  `Maintenance submenu includes a wired Restart Daemon item`.

## Operator waiver

On Wednesday, July 29, 2026, the operator explicitly waived the local
`env WIKIFS_APP_TESTS=1 TEST_TIMEOUT=60 make test-watchdog` wrapper exit `124`
for this PR as a known local infrastructure timeout rather than an
application-code blocker.

- Exact log path retained for the record:
  `tmp/test-logs/swift-test-20260729-100115.log`.
- GitHub CI remains the authoritative merge check for this head.
- AC.13's standard SwiftPM/CI evidence remains green:
  `make prompts` passed,
  `make build` passed,
  `make test` passed with `2653 tests in 215 suites`,
  and merge readiness still depends on green GitHub CI plus a fresh exact-head
  audit.

**Deferred chat-domain API surface explicitly preserved.**
- The foundation branch intentionally does **not** restore a public
  `ChatTimelineCursor` type.
- `ChatRuntimeSnapshot` intentionally does **not** carry a public
  `committedTranscriptCursor`; this branch keeps only the transient overlay plus
  `lastIncludedSequence`.
- Both omissions remain documented deferrals rather than silent removals; the
  queue/lifecycle fixes above do not change that Phase 0/1 boundary.

**Named test coverage shipped in this corrective branch.**
- `ChatIdentifierBoundaryTypecheckTests` maps to the current
  `IdentifierBoundaryTypecheckTests` suite plus the launcher/chat-domain
  positive fixtures and negative namespace fixtures it runs with
  `swiftc -typecheck`.
- `ChatDomainAPISignatureManifestTests` landed exactly as
  `ChatDomainAPISignatureManifestTests`.
- `ChatIdentifierCodableCompatibilityTests` landed exactly as
  `ChatIdentifierCodableCompatibilityTests`.
- `ChatSessionMachineTransitionTests`, `ChatSessionMachineStaleEventTests`, and
  `ChatCommandIdempotencyTests` are covered today by
  `ChatDomainStateTests` and `ChatDomainAuditRegressionTests`.
- `ChatTranscriptReducerTests` landed exactly as
  `ChatTranscriptReducerTests`.
- `ScriptedChatRuntimeTests` landed exactly as `ScriptedChatRuntimeTests`, with
  extra runtime seam coverage in `ChatAgentRuntimeCoverageTests`.

**Additional corrective regressions landed on Wednesday, July 29, 2026.**
- `ChatDomainAuditRegressionTests.transcriptChangedReplacementCoalescesExistingStreamingMessageAcrossSequences`
  proves the state machine coalesces a `messageDelta` followed by a
  `messageReplacement` for the same `ChatMessageID` into one overlay row across
  ordered sequences.
- `ChatDomainAuditRegressionTests.failedTurnWithQueuedFollowerDoesNotOrphanAttention`
  and
  `queuedTurnAfterTerminalFailurePreservesExistingQueueArrivalOrder`
  pin the failure/attention and queued-arrival invariants called out in the
  audit.
- `ChatDomainAuditRegressionTests.closedRecoveryDoesNotStrandQueuedTurns`
  now proves the preserved queue survives `sessionClosed`, re-promotes on
  `sessionReady`, and keeps later queued followers in arrival order.
- `BookmarkNodeStoreTests.retargetReferenceToMissingTargetIsRejected`
  now covers page/source/chat negative retargets, proving transactional target
  existence validation.
- `ScriptedChatRuntimeTests.storedGatePermitBeforeSubmitIsConsumedDeterministically`
  proves a gate resume recorded before submit/drain still releases the pause
  deterministically with no scheduler sleeps.
- `ChatDomainAuditRegressionTests.duplicateTerminalEventsAreRejected`,
  `staleTurnIDMismatchesAreRejected`,
  `permissionResolvedRejectsWrongRequestID`,
  `permissionResolvedRejectsWrongLifecycle`,
  `sessionClosedFromClosedLifecycleIsRejected`,
  `sessionReadyFromReadyLifecycleIsRejected`, and
  `recoveringRejectsIllegalLifecycles`
  now pin the exact negative AC.3 rejection results called out by the audit.
- `WikiStoreModelBookmarkMutationTests.renameBookmarkNodePropagatesStoreFailures`
  and `EditBookmarkSheetTests.folderRenameFailureReturnsVisibleErrorInsteadOfDismiss`
  prove the folder rename path now surfaces the store error instead of
  swallowing it.

**Follow-up on July 29, 2026.** The corrective branch
`chat-domain-audit-fixes` repaired that opt-in app-test drift and the hosted
`PageDetailView` inspector environment setup, and it added direct regression
coverage for the audit findings around exact JSON/raw-boundary compatibility,
state-machine failures and stale-event rejection, runtime forwarding, and
sleep-free scripted runtime behavior. The original foundation branch did not
make the opt-in aggregate app-test gate green, and the corrective branch still
does not have a successful aggregate app-test exit under the bounded watchdog
wrapper; as recorded above, the operator waived that local wrapper timeout for
this PR and kept GitHub CI as the authoritative gate.
