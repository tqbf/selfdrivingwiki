import Foundation
import WikiFSCore

/// Shared wait budget for "the bus delivered the events" polls in WikiFSTests.
/// The bus dispatches each handler as `Task { @MainActor in … }`, so under
/// full-suite load the delivery can trail the committing write by many
/// seconds: StoreConcurrencyTests failed its old 5-second budget exactly this
/// way (issue #1425). The budget absorbs that lag while staying far below the
/// waiting suites' per-test `.timeLimit` values, so a real emission regression
/// still fails, and fails fast, instead of racing the scheduler.
enum EventBusDeliveryWaits {
    /// Ceiling for one wait-for-delivery poll. Sized above any main-actor
    /// dispatch delay observed under full-suite load.
    static let budget: Duration = .seconds(30)

    /// Sleep between polls. Cooperative (`Task.sleep`), never a parked
    /// thread — the #1051 rule.
    static let pollInterval: Duration = .milliseconds(25)
}

enum EventBusDeliveryWaitError: Error, CustomStringConvertible {
    case timedOut(expectedCount: Int, actualCount: Int, timeout: Duration)

    var description: String {
        switch self {
        case let .timedOut(expectedCount, actualCount, timeout):
            "Timed out after \(timeout) waiting for \(expectedCount) event(s), received \(actualCount)."
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
    func awaitNonEmpty(timeout: Duration = EventBusDeliveryWaits.budget) async throws {
        let deadline = ContinuousClock.now + timeout
        while count == 0 {
            guard ContinuousClock.now < deadline else {
                throw EventBusDeliveryWaitError.timedOut(
                    expectedCount: 1,
                    actualCount: count,
                    timeout: timeout
                )
            }
            try Task.checkCancellation()
            await MainActor.run { }
            try? await Task.sleep(for: EventBusDeliveryWaits.pollInterval)
        }
    }
}

/// Yield to the main actor so any pending `Task { @MainActor in … }` bus
/// deliveries are flushed. Tests that poll for delivered events call this each
/// iteration so the dispatch runs promptly under parallel test load.
func flushBusDeliveries() async { await MainActor.run { } }
