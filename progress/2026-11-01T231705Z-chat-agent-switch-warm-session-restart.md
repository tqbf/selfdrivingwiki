---
timestamp: 2026-11-01T231705Z
title: Chat agent switch now restarts the warm session
branch: bugfix/chat-agent-switch-stale-session
status: historical
---

# Chat agent switch now restarts the warm session

## Progress

When a user changed the agent (provider + model) for an existing chat, the composer showed the new selection at once, but the next message still ran on the old provider and model. `ProviderSelector.selectRow` writes the new selection to the chat row, so the app side was correct. The daemon kept the chat's agent runtime warm across turns: `DaemonChatController` captured `runtimeStartRequest` at the first start and cleared it only on close. `processQueueIfPossible` returned that captured request on every warm drain, so the fresh row values were never read while the session stayed warm.

The fix adds a stale-session check to `processQueueIfPossible`, after the quiescence guards and before the `.preparing` claim:

- The controller now records the chat row's provider/model pin (`runtimeStartRowSelection`) when a cold preparation reads the row.
- On a warm drain, it reads the row again. If the pin changed, it runs the same idle close that `stopSession` uses (`record(.sessionClosed)`, clear the pending permission, `closeRuntimeAndRotateGeneration`), then continues the drain. The fresh preparation reads the new row values, and the turn starts on a new runtime.
- The mismatch also clears `chat.acp_session_id`. A resumed ACP session cannot honor a changed provider, and the resume path never applies a changed model, so a resume would silently keep the old agent. A fresh start rebuilds context through the continuation preamble — the same posture as a failed or collected resume. Both provider-only and model-only mismatches clear it.

Two findings shaped the comparison. First, the captured start request holds the runtime's resolved selection, not the row's pin: a nil row pin resolves to the stage default (`LauncherChatAgentRuntime.prepareStart`), and thinking model variants remap the model. A direct request-vs-row comparison restarts every warm turn of every chat without a row override — the `coldStartUsesOneAuthoritativeRuntimePreparation` contract test caught this — and would loop restarts for model-variant providers. The pin-at-capture comparison has no false positives. Second, a store read added at the dispatch capture site, before `startEventLoop`, deterministically flipped the timing in `syncUpdatesUseConsecutiveSequencesAndIgnoreLastActivityOnlyCompatibilityRefresh` and `transportCloseRotatesRuntimeAndRecoversOnNextTurn`; capturing inside the existing cold-path row read adds no store calls and no suspension points, so the drain timing stays unchanged. Also: do not add `.timeLimit` to this suite. Swift Testing wraps each test body in a raced child task to enforce the limit, and that alone flipped those two tests (verified with the annotation as the only change). The suite stays serialized through its `@MainActor` isolation.

Known limitation (unchanged by this fix): if the daemon fully restarts after a switch, the chat row's `acp_session_id` from before the switch resumes the old session, because the row does not record which provider/model created it. Session provenance on the row would fix this; the daemon-side fix cannot.

## Verification

- `make build` passes.
- `scripts/test-optin-app-tests-reconciled.sh --filter DaemonChatControllerTests` (the suite needs `WIKIFS_APP_TESTS=1`; a bare `swift test --filter` reports no matching test cases): 34/34 pass, two consecutive runs. New tests: `agentSwitchOnWarmSessionRunsNextTurnOnNewProviderAndModel`, `agentSwitchOnWarmSessionClearsPersistedResumeSessionId`, `unchangedAgentSelectionKeepsWarmRuntimeAndResumeIdUntouched`. The unchanged-row test also pins the no-close and no-write behavior.
- `make test` passes. The full default SwiftPM graph reports 5062 tests, 0 failures.
