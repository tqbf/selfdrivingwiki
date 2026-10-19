---
timestamp: 2026-10-19T034636Z
title: Deliver queued chat messages after the active run is cancelled
branch: fix/queued-message-strands-after-cancel
status: complete
---

# Deliver queued chat messages after the active run is cancelled

## Progress

Issue #1443: a message queued during a run stayed in the queue after Stop and was never sent.

Root cause: a settled cancellation closes the daemon runtime, so the projection has `lifecycle: .closed`. `RemoteChatSession` maps that projection to `ChatRunState.idle`, but `isReadyForLocalQueueDrain` required `.warm`. The normal Stop path therefore never became ready. Also, the view checked readiness only when `runState` changed. Readiness also depends on the attention, the daemon queue, and the active turn.

Changes:

- `isReadyForLocalQueueDrain` accepts `.idle` when a daemon projection exists. `.idle` with no projection, cancellation, cancellation failure attentions, daemon followers, and a non-terminal active turn still block the drain. `ChatRunState` did not change.
- `ChatDetailView` observes the readiness value directly. Auto-drain and the new Send Now action use one dispatch path. Dispatch removes the message before it submits. A failed submit puts the message back at the front of the queue with its error, logs it through `DebugLog`, and shows it in the preflight banner. Auto-drain holds a failed message until the user acts, so a failing submit cannot retry in a loop.
- `ChatOutgoingMessagesController.send` takes a `FailureRecovery` value. `.restoreDraft` is the default and keeps the composer behavior. `.returnToQueue` removes the echo row and gives the error to the caller.
- `ChatComposerPaneView` adds a Send Now button to each queued row and a "Not sent:" marker for a failed row. The daemon queues a submit that arrives during an active turn, so Send Now cannot interrupt the running turn.

No daemon or `SQLiteWikiStore` code changed.

## Verification

- `make build`: passed.
- `make test` (default tier): passed. 10 test runs, 5046 tests in 539 suites, 0 issues.
- New `ChatQueuedMessageAfterCancelHostedTests` (real `ChatDetailView`, coordinator, `RemoteChatSession`, and `DaemonChatController`; only the XPC hop and the agent process are stubbed) with `scripts/test-optin-app-tests-reconciled.sh --expect ChatQueuedMessageAfterCancelHostedTests --filter ChatQueuedMessageAfterCancelHostedTests`: 2 tests passed, and the opt-in and run-summary gates passed.
- With only the `RemoteChatSession` readiness fix reverted, the auto-submit test failed with 4 issues: the queued message never reached the daemon in 10 s. With the fix restored, it passed.
- Narrowed hosted run of the new suite, `ChatCancellationHostedScenarioTests`, `ChatOutgoingMessagesControllerTests`, `RemoteChatSessionTests`, `ChatCancellationControllerTests`, and `DaemonChatControllerTests`: 71 tests in 6 suites passed, and both gates passed.
- Hosted `--filter Chat`: 548 tests in 73 suites ran. Eight issues, all in `DaemonChatHostTests`. That suite also fails alone. Its tests expect `submitTurn` to throw a preflight error because no provider is configured. This machine resolves a real provider, so the submit succeeds. The suite tests the `wikid` target, which does not depend on the `WikiFS` target this change edits. The failure is environmental.
- Full hosted tier (`WIKIFS_APP_TESTS=1 make test`): not clean on this machine. Run 1 and run 2 both failed the run-summary gate with `started=11 summaries=10`. The `WikiFSAppTests` helper died about 28 s into its run, with no run summary and no new crash report in `~/Library/Logs/DiagnosticReports` (the #1422 signature). The new auto-submit test was in flight when the helper died in both runs. A third full run with `--skip ChatQueuedMessageAfterCancelHostedTests` failed the same way (`started=11 summaries=10`), so the new suite does not cause the death. All other test runs in those invocations summarized as passed. Run 1 also recorded one issue in `DaemonChatControllerTests.syncUpdatesUseConsecutiveSequencesAndIgnoreLastActivityOnlyCompatibilityRefresh` before the helper died. That test passed in the narrowed 71-test run, and this change does not touch the daemon controller.
