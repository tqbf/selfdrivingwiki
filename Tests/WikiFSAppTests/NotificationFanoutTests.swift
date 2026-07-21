#if os(macOS)
import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import ACPModel
@testable import WikiFS
@testable import WikiFSEngine

/// Unit tests for `NotificationFanout` — the session-lifetime notification drain
/// that fixes the per-turn AsyncStream re-acquisition race
/// (`plans/acp-stall-recovery.md` §1b).
///
/// These tests use `fanout.finish()` to end streams (NOT task cancellation —
/// `AsyncStream.Iterator.next()` does not reliably return on task cancellation
/// alone; the stream must be explicitly finished). This mirrors the real
/// `ACPBackend.cancel` path, which finishes the stream via `client.terminate()`.
@Suite struct NotificationFanoutTests {

    // MARK: - Helpers

    /// Build a `JSONRPCNotification` with a method + params dict.
    private func notification(_ method: String) -> JSONRPCNotification {
        JSONRPCNotification(
            method: method,
            params: AnyCodable(["key": "value"])
        )
    }

    // MARK: - Subscribe + yield

    @Test func subscriberReceivesYieldedNotifications() async {
        let fanout = NotificationFanout()
        let stream = fanout.subscribe()

        // Yield two notifications, then finish so the for-await exits.
        fanout.yield(notification("session/update"))
        fanout.yield(notification("session/update"))
        fanout.finish()

        var seen: [String] = []
        for await n in stream {
            seen.append(n.method)
        }
        #expect(seen == ["session/update", "session/update"])
    }

    @Test func yieldWithNoSubscriberIsHarmless() async {
        // Notifications yielded before any subscriber are silently dropped —
        // correct behavior (turns are serialized; the subscriber is always
        // registered before the prompt is sent in practice).
        let fanout = NotificationFanout()
        fanout.yield(notification("session/update")) // no subscriber yet
        // Should not crash and timestamp should still update.
        #expect(fanout.activityTimestamp <= Date())
    }

    // MARK: - Finish

    @Test func finishTerminatesSubscriber() async {
        let fanout = NotificationFanout()
        let stream = fanout.subscribe()

        fanout.yield(notification("session/update"))
        fanout.finish()

        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1) // the one notification before finish
    }

    @Test func finishIsIdempotent() async {
        let fanout = NotificationFanout()
        _ = fanout.subscribe()
        fanout.finish()
        fanout.finish() // should not crash
        #expect(Bool(true))
    }

    // MARK: - Liveness timestamp

    @Test func activityTimestampUpdatesOnYield() async {
        let fanout = NotificationFanout()
        let before = fanout.activityTimestamp

        try? await Task.sleep(nanoseconds: 50_000_000)
        fanout.yield(notification("session/update"))

        let after = fanout.activityTimestamp
        #expect(after > before)
    }

    @Test func activityTimestampInitializedToCreation() {
        let now = Date()
        let fanout = NotificationFanout()

        // The timestamp should be approximately "now" (creation time).
        let elapsed = fanout.activityTimestamp.timeIntervalSince(now)
        #expect(elapsed >= 0)
        #expect(elapsed < 1.0)
    }

    // MARK: - Resubscribe (turn boundary)

    @Test func newSubscriberReceivesOnlyNewNotifications() async {
        // Simulating a turn boundary: turn 1's subscriber is replaced by
        // turn 2's subscriber. Only turn 2 should receive new notifications.
        let fanout = NotificationFanout()

        // Turn 1 subscribes.
        _ = fanout.subscribe()

        // Turn 1 receives a notification.
        fanout.yield(notification("session/update"))

        // Turn 2 subscribes — replaces turn 1's subscriber.
        let stream2 = fanout.subscribe()

        // Turn 2 receives a notification.
        fanout.yield(notification("session/update"))
        fanout.finish()

        var methods: [String] = []
        for await n in stream2 {
            methods.append(n.method)
        }
        #expect(methods == ["session/update"])
    }
}
#endif
