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
    /// The process-global held flag. One instance per test process, shared by
    /// every suite that imports this target.
    private static let state = GateState()

    private final class GateState: @unchecked Sendable {
        private let lock = NSLock()
        private var held = false

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
    }

    struct GateTimeout: Error, CustomStringConvertible {
        var description: String {
            "another test still held the owned-process-group sweep gate past the timeout"
        }
    }

    /// Acquires the gate, polling until the deadline. Whichever comes first
    /// ends the wait: acquisition, the deadline, or cancellation of the
    /// calling task (for example a suite `.timeLimit`), because `Task.sleep`
    /// throws the moment the task is cancelled.
    static func acquire(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while state.tryAcquire() == false {
            if clock.now >= deadline { throw GateTimeout() }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func release() {
        state.release()
    }

    /// Runs `body` while holding the gate, releasing it on every exit path.
    /// The default timeout outlasts the longest legitimate holder (the
    /// end-to-end sweep test, which may wait for parallel suites' groups to
    /// drain first) while staying inside that suite's two-minute time limit.
    static func withExclusiveSweep<T: Sendable>(
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
    @Test func excludesASecondAcquirerUntilRelease() async throws {
        try await OwnedProcessGroupSweepGate.acquire(timeout: .seconds(5))

        let secondAcquired = await Task { () -> Bool in
            do {
                try await OwnedProcessGroupSweepGate.acquire(timeout: .milliseconds(100))
                OwnedProcessGroupSweepGate.release()
                return true
            } catch { return false }
        }.value
        OwnedProcessGroupSweepGate.release()

        #expect(secondAcquired == false)

        try await OwnedProcessGroupSweepGate.acquire(timeout: .seconds(5))
        OwnedProcessGroupSweepGate.release()
    }
}
