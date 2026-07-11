import Foundation
import ACPModel

/// Fans SDK `JSONRPCNotification`s to the single active turn subscriber.
///
/// **Why this exists (cause 6 from `plans/acp-stall-recovery.md`).** The SDK's
/// `Client.notifications` is backed by ONE stored `AsyncStream`. The old code
/// re-acquired that stream every turn (`ACPBackend.send` line 288), and
/// `AsyncStream` is single-consumer — two concurrent iterators (the prior turn's
/// not-yet-torn-down drain + the new turn's drain) split elements, silently
/// dropping notifications.
///
/// **The fix.** `ACPBackend.start` acquires `client.notifications` ONCE and runs
/// a session-lifetime drain Task that yields every notification into this fanout.
/// Each turn calls `subscribe()` to get its own stream; because turns are
/// serialized by the generation gate, at most one subscriber is active at a time.
///
/// **Liveness signal.** The fanout timestamps every notification it yields, so
/// `TurnLivenessPolicy` can check inactivity via `activityTimestamp` — no extra
/// plumbing needed.
///
/// **Concurrency.** `@unchecked Sendable` with an internal `NSLock` — the
/// readabilityHandler callback, the drain Task, and the watchdog Task all touch
/// it from different execution contexts.
final class NotificationFanout: @unchecked Sendable {

    private let lock = NSLock()
    private var subscriber: AsyncStream<JSONRPCNotification>.Continuation?
    private var _lastActivityAt: Date

    init() {
        _lastActivityAt = Date()
    }

    // MARK: - Subscriber (per-turn)

    /// Returns a new `AsyncStream` that receives notifications until the turn
    /// ends (the stream is torn down) or `finish()` is called at session
    /// teardown. Only one subscriber should be active at a time (turns are
    /// serialized by the generation gate).
    ///
    /// We deliberately do NOT set `onTermination` here: the old subscriber's
    /// termination fires asynchronously and can race with a new `subscribe()`,
    /// clearing the NEW subscriber's continuation (which hangs the new turn's
    /// drain). Instead, the subscriber is overwritten by the next `subscribe()`
    /// or cleared by `finish()` at teardown. Between turns there are no
    /// notifications (the agent is idle), so a stale continuation is harmless.
    func subscribe() -> AsyncStream<JSONRPCNotification> {
        AsyncStream { continuation in
            self.lock.lock()
            self.subscriber = continuation
            self.lock.unlock()
        }
    }

    // MARK: - Producer (session-lifetime drain)

    /// Yield a notification to the active subscriber (if any) and update the
    /// liveness timestamp. Called by the session-lifetime drain Task.
    func yield(_ notification: JSONRPCNotification) {
        lock.lock()
        _lastActivityAt = Date()
        subscriber?.yield(notification)
        lock.unlock()
    }

    /// Signal end-of-stream to the subscriber and clear it. Called at session
    /// teardown (`ACPBackend.cancel`). Idempotent.
    func finish() {
        lock.lock()
        subscriber?.finish()
        subscriber = nil
        lock.unlock()
    }

    // MARK: - Liveness

    /// The wall-clock time of the most recent `yield(_:)` call. Read by the
    /// turn watchdog to evaluate `TurnLivenessPolicy`. Initialized to the
    /// fanout's creation time (i.e. session start) so the first turn has a
    /// sensible baseline before any notification arrives.
    var activityTimestamp: Date {
        lock.lock()
        defer { lock.unlock() }
        return _lastActivityAt
    }
}
