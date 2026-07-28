---
timestamp: 2026-07-11T142229Z
title: "2026-07-11 — ACP stall recovery: app-side hang prevention (#334 Phase 1)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — ACP stall recovery: app-side hang prevention (#334 Phase 1)

## Progress


**Problem:** An ACP turn could stall permanently — `client.sendPrompt()` never
returns, the generation gate never releases, `isRunning` stays true, and the UI
shows no failure. Observed: the agent finished the work (page written) but the
`session/prompt` completion response never reached the app. Recovery required a
manual Stop.

**Root causes (6, all verified against code + SDK source):**
1. SDK: unordered chunk processing (`Task { processIncomingData }` per pipe
   chunk — ordering not guaranteed across actor hops).
2. SDK: `Client` actor head-of-line blocking on `request_permission`.
3. SDK: stderr discarded.
4. SDK: PID never exposed (`ProcessRegistry` is write-only).
5. App: no timeout/recovery (`sendPrompt` with `timeout: nil`; watchdog log-only).
6. App: per-turn `client.notifications` re-acquisition (AsyncStream is
   single-consumer — two concurrent iterators split elements).

**Phase 1 fixes (app-side, no SDK change — shippable alone):**

- **1a. Turn inactivity watchdog** (`TurnLivenessPolicy.swift`, new): a PURE
  decision helper — `(now, promptDone, turnStartedAt, lastActivityAt, limits) →
  .healthy | .stalled | .ceilingExceeded`. NOT a flat timeout (turns legitimately
  run 6+ min); the signal is *inactivity* (idle 120s default, ceiling 30 min).
  A sibling watchdog `Task` in `ACPBackend.send` polls every 15s; on stall it
  calls `cancelSession` + yields `turnEndEvents(error: .turnStalled(...))` +
  finishes the continuation. A shared `TurnCompletionFlag` prevents the prompt
  task and watchdog from double-firing.

- **1b. Session-lifetime notification drain** (`NotificationFanout.swift`, new):
  `client.notifications` is acquired ONCE in `ACPBackend.start` and fanned into a
  per-session `NotificationFanout`. Each turn subscribes to the fanout instead of
  re-acquiring the SDK stream (eliminates cause 6 — the single-consumer race).
  The fanout also timestamps every notification, giving 1a its liveness signal
  for free. Torn down in `cancel` (drainTask.cancel + fanout.finish).

- **1c. Stop-path audit + error synthesis:** `ACPBackendError` gains
  `.turnStalled(idleSeconds:)` and `.turnCeilingExceeded(totalSeconds:)`. The
  recovery reuses the existing `turnEndEvents(error:)` synthesis (`.raw` +
  `.messageStop`), so the consumer's `for await` exits, the generation gate
  releases, and the user sees an error line + can retry. `FakeAgentBackend`
  gains `neverFinish` to simulate a stalled `sendPrompt`.

**Concurrency design note:** `NotificationFanout.subscribe()` deliberately does
NOT set `onTermination` — the old subscriber's termination fires asynchronously
and can race with a new `subscribe()`, clearing the NEW subscriber's
continuation (which hangs the new turn's drain). The subscriber is overwritten
by the next `subscribe()` or cleared by `finish()` at teardown. Between turns
there are no notifications (the agent is idle), so a stale continuation is
harmless.

**Tests (24 new, all green):**
- `TurnLivenessPolicyTests` (11): healthy/stalled/ceiling/boundary/precedence.
- `NotificationFanoutTests` (7): subscribe/yield/finish/liveness/resubscribe.
- `ACPStallRecoveryTests` (6): neverFinish behavior, error messages,
  turnEndEvents synthesis for both stall + ceiling.

**Gate:** `swift build` clean; fast tier **2140 tests in 180 suites pass**.
Existing ACP tests (69 across 6 suites) unchanged. `ACPBackend.send` path not
unit-tested (requires a real `Client` actor from the SDK) — Phase 2's ship gate
(live-agent smoke) covers the full fire-and-recover path.

**Files changed:**
- `Sources/WikiFS/TurnLivenessPolicy.swift` (new) — pure decision helper.
- `Sources/WikiFS/NotificationFanout.swift` (new) — session-lifetime drain fanout.
- `Sources/WikiFS/ACPBackend.swift` — watchdog + fanout + stall errors + teardown.
- `Tests/WikiFSTests/TurnLivenessPolicyTests.swift` (new) — 11 tests.
- `Tests/WikiFSTests/NotificationFanoutTests.swift` (new) — 7 tests.
- `Tests/WikiFSTests/ACPStallRecoveryTests.swift` (new) — 6 tests.
- `Tests/WikiFSTests/FakeAgentBackend.swift` — `neverFinish` behavior.
- `plans/acp-stall-recovery.md` (new) — design doc of record.
- `PLAN.md` — doc index entry.

**Deferred (Phase 2):** Fork `wiedymi/swift-acp` for ordered transport reads,
non-blocking incoming requests, stderr forwarding, PID exposure. SDK upstream
confirmed dead since v0.1.0 (no fixes available). Phase 3: watchdog kill
escalation + UI surfacing.

## Verification

Historical verification remains in the progress record above.
