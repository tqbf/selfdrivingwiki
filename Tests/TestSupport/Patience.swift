import Foundation

/// Patience settings for tests that wait on scheduler-dependent work —
/// detached main-actor tasks, subprocesses, daemons — rather than compute
/// (#1051 discipline: bounded and interval-polled, never blocking).
///
/// Modeled on ScalaTest's `PatienceConfig` / `IntegrationPatience`: patience
/// values are named code, not environment knobs. A test declares HOW it waits
/// (`.unit` vs `.integration`); CI-vs-local differences are tuned by adjusting
/// the preset in this one place, not by per-test magic numbers.
public struct PatienceConfig: Sendable {
    /// How long the condition may take to land before the poll fails with a
    /// diagnosed `Patience.TimeoutError`.
    public let timeout: Duration

    /// How often the condition is re-checked. Short relative to the timeout:
    /// the wait's cost is scheduling, not the poll itself.
    public let interval: Duration

    public init(timeout: Duration, interval: Duration = .milliseconds(100)) {
        self.timeout = timeout
        self.interval = interval
    }
}

public extension PatienceConfig {
    /// Local-scale waits: the condition lands in-process, immediately, on any
    /// machine. A miss means something is genuinely wedged.
    static let unit = PatienceConfig(timeout: .seconds(5))

    /// Waits on integration surfaces whose landing time is scheduling, not
    /// compute: detached main-actor tasks, spawned wikictl children, the
    /// daemon. Shared CI runners starve these past local-scale budgets — a
    /// 30s leash was observed missed while concurrent 47-second suites
    /// finished — hence the generous timeout. A real wedge still fails here,
    /// with the same diagnosed message. Tune this one constant if your CI
    /// environment is slower or faster than the shared runner.
    static let integration = PatienceConfig(timeout: .seconds(120))
}

/// Shared patience presets and the poll helper that applies them.
public enum Patience {
    /// The condition was still false when the patience timeout expired.
    public struct TimeoutError: Error, CustomStringConvertible {
        public let message: String
        public let waited: Duration

        public var description: String {
            "\(message) did not land within \(waited)"
        }
    }

    /// Polls `condition` every `config.interval` until it returns true or
    /// `config.timeout` expires, then throws a diagnosed `TimeoutError`.
    /// Non-blocking throughout: the poll sleeps, it never parks a
    /// cooperative-pool thread (#1051).
    public static func poll(
        until condition: @Sendable () async throws -> Bool,
        config: PatienceConfig = .integration,
        description: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: config.timeout)
        while true {
            if try await condition() { return }
            guard clock.now < deadline else {
                throw TimeoutError(message: description, waited: config.timeout)
            }
            try await Task.sleep(for: config.interval)
        }
    }
}
