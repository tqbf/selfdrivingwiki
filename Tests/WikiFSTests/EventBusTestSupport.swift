import Foundation
import WikiFSCore

/// Shared test support: a thread-safe recorder for `ResourceChangeEvent` plus a
/// bounded "wait for the async bus delivery" helper. The bus dispatches each
/// `@MainActor` handler via `Task { @MainActor in … }`, so delivered events land
/// a runloop tick after `emit`; tests poll until they arrive (no timing flakes).
final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ResourceChangeEvent] = []
    func append(_ event: ResourceChangeEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
    var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }

    /// Wait until at least one event has been delivered (bounded), so a missing
    /// delivery fails the test rather than hanging. Each iteration flushes the
    /// main actor (`await MainActor.run { }`) so the bus's `Task { @MainActor in … }`
    /// dispatch path runs promptly even under parallel test load, where
    /// `Task.sleep` alone may not pump the main run loop.
    func awaitNonEmpty(timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while Date() < deadline {
            if count > 0 { return }
            await MainActor.run { }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Yield to the main actor so any pending `Task { @MainActor in … }` bus
/// deliveries are flushed. Tests that poll for delivered events call this each
/// iteration so the dispatch runs promptly under parallel test load.
func flushBusDeliveries() async { await MainActor.run { } }
