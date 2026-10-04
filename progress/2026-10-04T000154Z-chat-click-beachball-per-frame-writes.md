---
timestamp: 2026-10-04T000154Z
title: Chat click beachball diagnosed live, per-frame writes removed, live cure unconfirmed
branch: feature/wiki-strategies-cumulative-ingestion
status: complete
---

# Chat click beachball diagnosed live, per-frame writes removed, live cure unconfirmed

## Progress

The user clicked chat `01M41RK6BT9VKFASJEA314EKSQ` (wiki
`01M41BV9H7N34EAW18R7G9SQEP`) at 15:57:48 PDT on 2026-10-03. The window showed
a spinning wheel and no content. The suspected daemon crash was wrong. Both
processes stayed alive: wikid pid 85572 ran at 0% CPU and finished its queue
run at 16:11:34. The app pid 85484 burned a full core for more than 45 minutes
after that, with the daemon idle. The hang lives in the app alone.

Debugger evidence (lldb attach, detach without quit; `sample 85484 5`):

- The main thread was not blocked. It ran inside `ChatDetailView.body` →
  `ChatTranscriptPresentationProjection.summarizedRows` →
  `ChatToolCallGroupState.aggregating`, over 140 persisted transcript items
  (34 messages, 106 tool calls). 1,703 of 2,317 main-thread samples sat in
  that body across five seconds.
- Auto-continue breakpoints counted the loop rate.
  `ChatDetailPresentation.make` hit about 84 times per second. Each body pass
  re-derives the full presentation four to five times (`displayRows`,
  `outlinePayload`, `liveDebugKey`, `transcriptContent`). So the body ran
  about 21 times per second, near frame rate.
  `ComposerTextView.Coordinator.recomputeHeight` hit about 71 times per
  second, called from `updateNSView` through a plain transaction flush.
  `ChatDaemonCoordinator.session(wikiID:for:)` hit about 78 times per second,
  so the parent (`WikiDetailView.chatSurface`) re-evaluated every frame.
- The deferred composer height write never executed. Breakpoints at the
  assignment inside the task body hit zero times in six seconds while task
  creation hit 449 times. The captured values explain the non-convergence:
  `measuredHeight` stayed 56 (the `@State` seed from a detached
  `NSLayoutManager`) while the in-situ layout measured a 64.59 minimum. The
  guard passed every frame and the write never landed.
- Ruled out with direct measurement: daemon death (never exited), an RPC or
  transport hang (`chatSessionState` is timeout-bounded and no failure was
  logged), queue-event flooding (the loop persisted after the run finished),
  a session effect cycle (`ChatDiagnostics.observe` hit zero times in seven
  seconds), SwiftUI runtime issues (zero events in a twelve-second stream),
  and composer remount churn (`makeNSView` hit zero times).

Two per-frame defects were fixed. `ChatDaemonCoordinator.session(wikiID:for:)`
now writes `chatWikiIDs[chatID] = wikiID` only when the pairing differs; the
old code mutated `@Observable` state on every body evaluation. The composer
coordinator now keeps at most one deferred height write in flight per value,
drops a superseded pending value when the measurement returns to the published
height, and skips a drain whose value equals the published height.

Honest limits of the fix. The hosted harness did not reproduce the live loop.
It stayed quiet even with both changes reverted, with the real fixture shape
(140 items, 106 tool calls, two stranded `running` items) and a
`chatSurface`-style parent. The hosted suite is a quiet-CPU contract guard,
not a reproducer. Dictionary subscript mutation takes the `_modify` path,
which does not notify observers on this toolchain, so the exact live
invalidation edge is not proven. The cure is therefore not confirmed. It
needs a relaunch with these changes and one click on the same chat. The
operator owns that restart. If the loop persists, the next suspect is the
WKWebView transcript renderer's per-frame callbacks; instrument
`ChatTranscriptView` script-message handling with `DebugLog` per the
reproducing-live-ui-bugs procedure. Follow-up worth its own change: derive
`presentation` once per body pass instead of four to five recomputes, and
terminalize stranded `running` tool-call items in daemon bootstrap.

## Evidence

- lldb artifacts: `tmp/lldb-app-85484.out` (thread backtrace all, detach
  clean), `tmp/lldb-values.out` (56 vs 64.59 pair), `tmp/lldb-rate2.out`
  (make 675/8 s), `tmp/lldb-rate4.out` (recomputeHeight 499/7 s),
  `tmp/lldb-rate6.out` (task creation 449/6 s), `tmp/lldb-rate9.out`
  (session 465/6 s), `tmp/lldb-bt-rh.out` (updateNSView caller),
  `tmp/sample-app-85484.txt` (5 s profile).
- App-side trace: `tmp/live-app-daemon-trace.log`; queue item
  `01M41ZRVW47MJ72J7DX0CTGXDG` completed 16:11:34 PDT while the app kept a
  full core (read-only `sqlite3 file:queue.sqlite?mode=ro`).
- Fixtures extracted read-only: `tmp/chat-01M41RK6-items.jsonl` (140 items,
  statuses 103 completed, 1 failed, 2 running).
- Targeted opt-in, `WIKIFS_APP_TESTS=1 swift test --filter
  'ComposerTextViewTests|ChatDaemonCoordinatorTests|ChatStuckRunningBeachballReproTests'`
  — 46 tests in 3 suites passed. New cases: repeated `session(wikiID:for:)`
  emits no Observation invalidation (`withObservationTracking`, with a
  whole-property-write positive control), a pairing change still lands, one
  write for repeated recomputes, latest-desired supersession, drain-time
  stale skip, a future same-height update is not lost, and coordinator
  deallocation before drain writes nothing.
- `make build` produced a signed app. `caffeinate -i make test` passed the
  full suite.
- The live app was never stopped, restarted, or rebuilt onto. No paid calls
  ran. Live databases were read only with `mode=ro`.
