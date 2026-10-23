import Foundation

/// Environment-scalable poll leashes for tests that wait on detached tasks,
/// subprocesses, or scheduler-dependent work (#1051 discipline: bounded, but
/// never blocking).
///
/// CI runners vary widely in load (shared 3-vCPU runners vs 8+-core local
/// machines), so a hardcoded leash either flakes under saturation or hides
/// real wedges behind generous padding. Scale per environment instead: the
/// default serves local runs, and the workflow exports a larger value where
/// the runner is known to be slow.
public enum TestTimeouts {
    /// Environment variable overriding a leash's default duration, in
    /// seconds. Missing or unparseable values fall back to the default.
    public static let leashSecondsEnvironmentKey = "WIKI_TEST_LEASH_SECONDS"

    /// A poll leash scaled for the current environment: the value of
    /// ``leashSecondsEnvironmentKey`` when it parses as a positive number of
    /// seconds, otherwise `defaultSeconds`.
    ///
    /// The result is floored at one second so a nonsense override degrades to
    /// a (short) diagnosed failure instead of an instant, evidence-free one.
    public static func leash(
        defaultSeconds: Double = 30,
        environmentVariable: String = leashSecondsEnvironmentKey
    ) -> Duration {
        let parsed = ProcessInfo.processInfo.environment[environmentVariable]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { Double($0) }
        // A zero/negative override degrades to the default rather than an
        // instant, evidence-free leash failure.
        let seconds = parsed.flatMap { $0 > 0 ? $0 : nil } ?? defaultSeconds
        return .seconds(max(1, seconds))
    }
}
