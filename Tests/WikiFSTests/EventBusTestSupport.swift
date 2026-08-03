import Foundation
import WikiFSCore

enum EventBusDeliveryWaitError: Error, CustomStringConvertible {
    case timedOut(expectedCount: Int, actualCount: Int, timeoutMs: Int)

    var description: String {
        switch self {
        case let .timedOut(expectedCount, actualCount, timeoutMs):
            "Timed out after \(timeoutMs)ms waiting for \(expectedCount) event(s); received \(actualCount)."
        }
    }
}

/// Shared test support: a thread-safe recorder for `ResourceChangeEvent` plus a
/// bounded "wait for the async bus delivery" helper. The bus dispatches each
/// `@MainActor` handler via `Task { @MainActor in … }`, so tests wait for an
/// observed delivery rather than a fixed delay.
final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ResourceChangeEvent] = []
    func append(_ event: ResourceChangeEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
    var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }

    /// Wait until at least one event has been delivered. A missing delivery
    /// throws with the observed count instead of silently returning.
    func awaitNonEmpty(timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        while true {
            if count > 0 { return }
            guard Date() < deadline else {
                throw EventBusDeliveryWaitError.timedOut(
                    expectedCount: 1,
                    actualCount: count,
                    timeoutMs: timeoutMs
                )
            }
            await MainActor.run { }
            await Task.yield()
        }
    }
}

/// Yield to the main actor so any pending `Task { @MainActor in … }` bus
/// deliveries are flushed. Tests that poll for delivered events call this each
/// iteration so the dispatch runs promptly under parallel test load.
func flushBusDeliveries() async { await MainActor.run { } }
