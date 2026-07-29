---
timestamp: 2026-07-29T074900Z
title: "2026-07-29 — Chat domain foundation Phase 0/1 (#982)"
branch: chat-domain-foundation
status: complete
---

# 2026-07-29 — Chat domain foundation Phase 0/1 (#982)

## Progress

**Scope.** This branch lands only the foundation slice of the reviewed chat
architecture redesign for issue #982. It intentionally stops before schema v46,
durable turn persistence, daemon controller replacement, XPC migration, client
synchronization, and UI decomposition.

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
  and a closure-backed seam for production adaptation work in later phases.
- Added `ScriptedChatRuntime` test support with deterministic pause gates,
  generation-preserving event envelopes, and sleep-free teardown behavior. The
  gate implementation was corrected to use stored permits so a resume cannot be
  lost if it arrives before the drain task parks.
- Added Phase 0/1 guardrails:
  `ChatIdentifierCodableCompatibilityTests`,
  `ChatDomainStateTests`,
  `ChatTranscriptReducerTests`,
  `ScriptedChatRuntimeTests`,
  `ChatDomainAPISignatureManifestTests`,
  and new `IdentifierBoundaryTypecheckTests` fixtures for turn, message,
  command, and permission/tool-call namespace boundaries.

**Important compatibility decisions preserved.**
- Raw identifier text stayed primitive-string-compatible at JSON and Codable
  boundaries.
- `AcpSessionID` remains the provider-session namespace; no duplicate wrapper
  was introduced.
- The new transcript vocabulary is Foundation-only and does not pull Engine or
  Core dependencies into `WikiFSTypes`.
- No schema migration, chat-row compatibility decoder, or UI migration landed
  in this branch.

## Verification

- `make prompts` — passed.
- Focused Phase 0/1 foundation verification:
  `swift test --filter 'ChatDomainAPISignatureManifestTests|IdentifierBoundaryTypecheckTests|ChatIdentifierCodableCompatibilityTests|ChatDomainStateTests|ChatTranscriptReducerTests|ScriptedChatRuntimeTests'`
  — 43 tests in 6 suites passed.
- `swift build` — passed.
- First `swift test` run surfaced one failure in
  `StoreEmissionTests.revertProcessedMarkdownUnknownVersionEmitsNothingAndKeepsHeadUnchanged`.
  A focused rerun of that test passed immediately, indicating a flaky unrelated
  expectation rather than a deterministic regression from this branch.
- Second `swift test` run — 2,614 tests in 212 suites passed.
- `WIKIFS_APP_TESTS=1 swift test` did **not** pass. The opt-in app test target
  currently contains unrelated compile drift where tests still pass raw
  `String` values into newer `ModelID`/`ProviderID`-typed APIs, for example in
  `Tests/WikiFSAppTests/RunAwaitsTurnTests.swift:60`,
  `ACPChatResumeTests.swift:51`, `ACPProviderModelProbeTests.swift`, and
  `AgentProviderModelTests.swift`. This branch did not touch those APIs or
  those app tests, so the failure is recorded here rather than broadened into a
  separate typed-model migration.
