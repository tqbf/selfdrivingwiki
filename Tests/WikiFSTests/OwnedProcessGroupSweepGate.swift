import Foundation
import Testing

/// Cross-suite mutual exclusion for tests that sweep the process-global
/// `OwnedProcessGroupRegistry`.
///
/// `@Suite(.serialized)` orders tests only inside one suite; Swift Testing
/// runs distinct suites in parallel inside one test process. The registry is
/// process-global, so two sweeping tests from different suites can interleave:
/// one suite's sweep can kill the other suite's in-flight fixture group, and
/// one suite's registrations can pollute the other's registry-count
/// assertions. Every test that sweeps `terminateAllOwnedGroups`, or registers
/// a group another sweeper could observe, takes this gate for its whole body.
///
/// The gate never blocks a cooperative-pool thread (#1051): waiting is
/// deadline-bounded `Task.sleep` polling, so task cancellation and timeout
/// both surface as a fast, diagnosed failure instead of a hang.
enum OwnedProcessGroupSweepGate {
    /// The process-global gate shared by every sweeping suite. Holders keep
    /// it legitimately for tens of seconds — the end-to-end sweep test waits
    /// for parallel suites' groups to drain first — so the gate's own
    /// selftest below must not race this instance; it uses a private one.
    private static let global = SweepGate()

    static func acquire(timeout: Duration) async throws {
        try await global.acquire(timeout: timeout)
    }

    static func release() {
        global.release()
    }

    /// Runs `body` while holding the gate, releasing it on every exit path.
    /// The default timeout outlasts the longest legitimate holder (the
    /// end-to-end sweep test, which may wait for parallel suites' groups to
    /// drain first) while staying inside that suite's two-minute time limit.
    static func withExclusiveSweep<T: Sendable>(
        timeout: Duration = .seconds(90),
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await global.withExclusiveSweep(timeout: timeout, body)
    }
}

/// One mutual-exclusion gate with deadline-bounded acquisition. The sweep
/// suites share a single process-global instance through
/// `OwnedProcessGroupSweepGate`; a test that only verifies the gate's own
/// semantics allocates a private instance so its timings race no parallel
/// suite's legitimate hold.
private final class SweepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    struct GateTimeout: Error, CustomStringConvertible {
        var description: String {
            "another test still held the owned-process-group sweep gate past the timeout"
        }
    }

    func tryAcquire() -> Bool {
        lock.withLock {
            if held { return false }
            held = true
            return true
        }
    }

    func release() {
        lock.withLock { held = false }
    }

    /// Acquires the gate, polling until the deadline. Whichever comes first
    /// ends the wait: acquisition, the deadline, or cancellation of the
    /// calling task (for example a suite `.timeLimit`), because `Task.sleep`
    /// throws the moment the task is cancelled.
    func acquire(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while tryAcquire() == false {
            if clock.now >= deadline { throw GateTimeout() }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func withExclusiveSweep<T: Sendable>(
        timeout: Duration = .seconds(90),
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(timeout: timeout)
        defer { release() }
        return try await body()
    }
}

@Suite("Owned process group sweep gate", .serialized, .timeLimit(.minutes(1)))
struct OwnedProcessGroupSweepGateTests {
    /// While the gate is held, a second acquire fails at its own deadline;
    /// after release, acquire succeeds again.
    ///
    /// Runs against a dedicated `SweepGate` instance, not the process-global
    /// gate: parallel suites legitimately hold the global gate for tens of
    /// seconds, so racing this test's 5 s acquires against them measures
    /// cross-suite scheduling, not gate semantics.
    @Test func excludesASecondAcquirerUntilRelease() async throws {
        let gate = SweepGate()
        try await gate.acquire(timeout: .seconds(5))

        let secondAcquired = await Task { () -> Bool in
            do {
                try await gate.acquire(timeout: .milliseconds(100))
                gate.release()
                return true
            } catch { return false }
        }.value
        gate.release()

        #expect(secondAcquired == false)

        try await gate.acquire(timeout: .seconds(5))
        gate.release()
    }
}
