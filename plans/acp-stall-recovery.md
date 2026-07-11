# ACP stall recovery — executable plan for #334

Issue: https://github.com/tqbf/selfdrivingwiki/issues/334
Design source: fable plan (2026-07-11), validated line-by-line against the code.

## Problem

An ACP turn can stall permanently: `client.sendPrompt()` never returns, the
generation gate never releases, `isRunning` stays true, and the UI shows no
failure. Observed 2026-07-11: the agent subprocess finished the work (page
written) but the `session/prompt` completion response never reached the app.
Recovery requires a manual Stop.

## Verified root causes

All confirmed against the code.

| # | Layer | Cause | Evidence |
|---|-------|-------|----------|
| 1 | SDK | Unordered chunk processing can silently drop messages | `StdioTransport.startReading()` spawns `Task { processIncomingData }` per chunk — order not preserved; decode failures dropped with `logger.warning` only |
| 2 | SDK | `Client` actor head-of-line blocking | `handleMessage` awaits `requestRouter.routeRequest` inline — a pending `session/request_permission` freezes all processing |
| 3 | SDK | stderr discarded | `startReadingStderr` reads and ignores |
| 4 | SDK | PID never exposed | `ProcessRegistry` records pid/pgid but no API; `AgentLauncher.currentProcessID` stays `nil` (only ever assigned `nil` — grep confirms 4 sites, all cleanup) |
| 5 | App | No timeout/recovery | `ACPBackend.swift:306` — `sendPrompt` with no timeout; watchdog (`AgentLauncher.swift:1414-1427`) is log-only |
| 6 | App | Per-turn notification re-acquisition | `ACPBackend.swift:288` — `await client.notifications` inside per-turn `promptTask`; AsyncStream is single-consumer, so a second turn's iterator competes with the first |

## Design decision

Causes 1–4 are inside swift-acp and cannot be fixed by wrapping. **Phase 1
fixes causes 5–6 (app-side, no SDK change) and makes the app degrade to a
failed turn — never a frozen session.** Phases 2–3 fix the SDK root causes
and add escalation; they land later as defense in depth.

---

## Phase 1 — app-side hang recovery (ships independently)

### 1a. Turn inactivity watchdog in `ACPBackend.send`

**Insight:** NOT a flat prompt timeout — the observed turn legitimately ran 6
minutes. The correct signal is **inactivity**: the agent is healthy iff
`session/update` notifications keep arriving.

**New pure helper — `TurnLivenessPolicy`:**

```swift
enum TurnLivenessPolicy {
    enum Decision: Equatable {
        case healthy
        case stalled(idleSeconds: TimeInterval)
        case ceilingExceeded(totalSeconds: TimeInterval)
    }

    /// PURE — unit-tested directly. No actor, no clock side-effects.
    static func evaluate(
        now: Date,
        promptDone: Bool,
        turnStartedAt: Date,
        lastActivityAt: Date,          // from the session drain (1b)
        idleTimeout: TimeInterval,     // default 120s
        ceilingTimeout: TimeInterval   // default 1800s (30 min)
    ) -> Decision
}
```

Decision order: `promptDone` → `.healthy`; ceiling exceeded →
`.ceilingExceeded`; idle exceeded → `.stalled`; else `.healthy`.

**`send` wiring:** alongside the existing `promptTask`, spawn a sibling
watchdog `Task` that wakes every ~15s and calls
`TurnLivenessPolicy.evaluate(...)`. On `.stalled`/`.ceilingExceeded`:

1. Mark the turn done (so the prompt task's `defer` path doesn't double-fire).
2. `client.cancelSession(sessionId:)` best-effort.
3. `yield` `turnEndEvents(error: .turnStalled(idleSeconds:))` — reuses the
   existing `.raw` + `.messageStop` synthesis, so the consumer's `for await`
   exits, the generation gate releases, and the user sees an error line + can
   retry.
4. `continuation.finish()`.

**Hard ceiling:** default 30 min — backstop against an agent that streams
heartbeat-ish updates forever without finishing.

**New error case:**

```swift
// ACPBackendError
case turnStalled(idleSeconds: TimeInterval)
// errorDescription: "ACP agent stalled — no activity for \(seconds)s. The turn was cancelled; try sending again."
```

### 1b. Session-lifetime notification drain (fixes cause 6)

**Problem today:** `send` re-awaits `client.notifications` every turn (line
288). The SDK backs it with ONE stored `AsyncStream`; two concurrent iterators
(one per turn, during the teardown window) split elements → lost/misrouted
events.

**Fix:** acquire `client.notifications` **once** in `start`; run one
session-lifetime drain task that fans events into a per-session fanout. `send`
subscribes to the fanout instead of re-acquiring the SDK stream.

**New class — `NotificationFanout`:**

```swift
/// Fans SDK notifications to the single active turn subscriber (turns are
/// serialized by the generation gate, so at most one subscriber at a time).
/// Also timestamps every notification — the liveness signal for 1a.
final class NotificationFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriber: AsyncStream<JSONRPCNotification>.Continuation?
    private var lastActivityAt: Date

    init() { lastActivityAt = Date() }

    /// Called by `send` — returns a new stream that receives notifications
    /// until the turn ends or the subscriber is torn down.
    func subscribe() -> AsyncStream<JSONRPCNotification>
    /// Called by the session drain task for every notification.
    func yield(_ notification: JSONRPCNotification)
    /// Called at session teardown.
    func finish()
    /// The timestamp of the most recent notification (for the watchdog).
    var activityTimestamp: Date { get }
}
```

**`ACPSession` gains two fields:**

```swift
private struct ACPSession: Sendable {
    let client: Client
    let sessionId: SessionId
    let permissionDelegate: ACPPermissionDelegate
    let modelsInfo: ModelsInfo?
    let notificationFanout: NotificationFanout   // NEW
    let drainTask: Task<Void, Never>             // NEW — cancelled in `cancel`
}
```

**`start` starts the drain:**

```swift
let fanout = NotificationFanout()
let drainTask = Task { [client, fanout] in
    let notifications = await client.notifications
    for await notification in notifications {
        if Task.isCancelled { break }
        fanout.yield(notification)
    }
    fanout.finish()
}
// Store both on the ACPSession record.
```

**`send` subscribes instead of re-acquiring:**

```swift
// OLD (line 288): let notifications = await client.notifications
// NEW:
let updates = session.notificationFanout.subscribe()
let drainTask = Task {
    for await notification in updates {
        if Task.isCancelled { return }
        guard notification.method == "session/update" else { continue }
        // ... existing translateNotification → yield logic ...
    }
}
```

**`cancel` tears down:**

```swift
record.drainTask.cancel()
record.notificationFanout.finish()
```

### 1c. Stop-path audit

Verify Stop works while stalled. The risk: `sendPrompt` suspends on a
continuation the SDK may not tie to task cancellation, so `promptTask.cancel()`
in `onTermination` may not unblock it. Ensure `ACPBackend.cancel`'s
`client.terminate()` is what actually unblocks a stuck `sendPrompt`.

- Confirm the launcher's Stop button → `stopAgent()` → `cancel()` path works
  even mid-turn (it should — `cancel` calls `client.cancelSession` +
  `client.terminate`).
- Add a launcher-level test with `FakeAgentBackend` whose `send` never finishes
  the stream, then call `stopAgent()` and assert `isRunning` → `false` +
  generation gate released within a bounded time.

---

## Phase 2 — SDK fork fixes (deferred; medium risk)

Fork `wiedymi/swift-acp` under our org, pin `Package.swift` to the fork, offer
fixes upstream as PRs. Each fix is a separately upstreamable commit:

1. **Ordered transport reads.** Replace Task-per-chunk with an ordered
   `AsyncStream<Data>` pipe + ONE long-lived consumer calling
   `processIncomingData` (same fix in `StdioTransport` + `ProcessManager`).
2. **Non-blocking incoming requests.** Wrap `.request` handling in `Task { }`
   in `Client.handleMessage` so permission prompts can't freeze the actor.
3. **Stderr forwarding.** `startReadingStderr` yields lines to a new
   `stderrLines: AsyncStream<String>` on `Client` (default consumer: none).
   App wires it to `DebugLog.agent` + `run.stderr.log`.
4. **PID exposure.** `Client.processIdentifier: Int32?` from `ProcessRegistry`.
   App threads it to `AgentLauncher.currentProcessID`.
5. **Optional default `sendPrompt` timeout** — nice-to-have; 1a doesn't depend
   on it.

**Ship gate:** live-agent smoke — multi-turn session incl. always-ask
permission mid-turn.

---

## Phase 3 — observability & watchdog escalation (deferred; after 2.4)

- Launcher watchdog: when `isRunning` and idle exceeds a threshold, log at
  warning with pid + last event. With Phase 2.4, escalate: cancel → wait 10s →
  `SIGTERM` pgid → wait → `SIGKILL`, then synthesize turn end via `onExit`.
- Surface stall state in the UI: the `lastActivityAt` heartbeat already feeds
  the "quiet for Ns" affordance; add an explicit "agent stalled — stopped after
  Ns idle" transcript line from 1a.
- **Keep** the send/prompt lifecycle `TEMP DEBUG` lines (retag as permanent) —
  this incident was only diagnosable because of them. Strip the raw
  session/update JSON dump (too noisy) but keep the lifecycle markers.

---

## Test plan (Phase 1)

### Pure unit tests — `TurnLivenessPolicyTests.swift` (new)

- `healthyWhenPromptDone` — returns `.healthy` regardless of idle
- `healthyWithRecentActivity` — idle below threshold → `.healthy`
- `stalledAfterIdleTimeout` — idle exceeds threshold → `.stalled`
- `stalledWhenNeverActiveAndThresholdPassed` — `lastActivityAt == turnStartedAt`,
  idle exceeds → `.stalled`
- `ceilingExceededAfterMaxDuration` — total exceeds ceiling → `.ceilingExceeded`
- `ceilingTakesPrecedenceOverIdle` — both exceeded → `.ceilingExceeded`
- `ceilingNotTriggeredWhileActive` — active but under ceiling → `.healthy`

### Unit tests — `NotificationFanoutTests.swift` (new)

- `subscriberReceivesYieldedNotifications`
- `lateSubscriberOnlyGetsNewNotifications` (turns serialized — subscribe after
  some notifications, only gets subsequent ones)
- `finishTearsDownSubscriber`
- `activityTimestampUpdatesOnYield`
- `activityTimestampReadIsThreadSafe` (concurrent yield + read)

### Launcher-level test — stop-while-stalled (1c)

Using `FakeAgentBackend` with a `send` that yields events but never finishes
the stream:

- `stopAgentReleasesGateOnNeverFinishingStream` — call `stopAgent()`, assert
  `isRunning → false` + gate released within bounded time.

### Existing tests (regression)

- `ACPBackendTests` — translator, permission delegate, turn-boundary contract
  all unchanged (no behavioral change to those paths).
- Fast tier: `swift test --skip` regex (unchanged).

---

## Files touched (Phase 1)

| File | Change |
|------|--------|
| `Sources/WikiFS/ACPBackend.swift` | Add `NotificationFanout` class; refactor `start` (drain), `send` (subscribe + watchdog), `cancel` (teardown); add `turnStalled` error case |
| `Sources/WikiFS/TurnLivenessPolicy.swift` (**new**) | Pure decision helper |
| `Tests/WikiFSTests/TurnLivenessPolicyTests.swift` (**new**) | 7 pure tests |
| `Tests/WikiFSTests/NotificationFanoutTests.swift` (**new**) | 5 fanout tests |
| `Tests/WikiFSTests/ACPStallRecoveryTests.swift` (**new**) | 1c stop-while-stalled test |
| `PROGRESS.md` | Entry |

## Acceptance criteria (Phase 1)

1. `TurnLivenessPolicy` — 7 pure tests pass.
2. `NotificationFanout` — 5 tests pass.
3. A stalled `sendPrompt` (no notifications for 120s) yields a `.raw` error
   line + `.messageStop`, the consumer's `for await` exits, and the generation
   gate releases — verified by the launcher-level test.
4. Stop while stalled recovers within bounded time (1c test).
5. `swift build` clean; fast tier passes.
6. The per-turn notification re-acquisition race (cause 6) is eliminated
   (single drain, single subscriber per turn).
