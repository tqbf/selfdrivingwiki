import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// The #1330 repro reduced to in-process form: the daemon-quit seam kills a
/// real in-flight managed operation even though no cooperative-pool
/// cancellation path ran.
///
/// The real production composition is exercised: a real
/// `ManagedExtractorProcessExecutor` launches the real fixture executable,
/// which stalls mid-run (progress frame delivered, no output file, no
/// terminal frame). The quit backstop then kills the group from outside the
/// executor. The executor observing its own process die by signal is the
/// in-band proof that the group really died.
///
/// Spawn jitter and retry: a pipe-inheritance race in
/// `RaceFreeProcessGroupRunner.launch` used to starve two
/// concurrently-spawned operations of stdin EOF (each child inherited the
/// other's stdin write end, because the pipe fds were not close-on-exec);
/// #1334 marks every runner pipe descriptor close-on-exec and sets
/// POSIX_SPAWN_CLOEXEC_DEFAULT. The jitter and retry stay: they cost
/// little, and they absorb a future regression in the same window without
/// weakening any assertion.
///
/// This test runs a real global sweep of the process-global registry, so it
/// takes `OwnedProcessGroupSweepGate` for its whole body: `.serialized`
/// orders only this suite, while the registry suites in this target sweep
/// the same global registry in parallel.
@Suite("Quit backstop end-to-end", .serialized, .timeLimit(.minutes(2)))
struct QuitBackstopEndToEndTests {
    /// The quit backstop kills a real in-flight managed operation (#1330).
    ///
    /// No executor cancellation, timeout, or completion hook takes part: the
    /// sweep alone ends the operation. Without the backstop, the fixture
    /// would stall for its full 60 s limit — the in-process shape of an
    /// orphaned `uv run` wrapper outliving its supervisor.
    @Test func quitBackstopKillsAnInFlightManagedOperation() async throws {
        // The gate spans every attempt: the real global sweep below must not
        // interleave with the other gated suites' registry registrations or
        // sweeps.
        try await OwnedProcessGroupSweepGate.withExclusiveSweep {
            // Up to three spawn attempts; see the suite doc for why the first
            // can starve on stdin EOF when a parallel suite spawns at the same
            // instant. A retry costs one bounded wait and changes no assertion.
            for attempt in 1...3 {
                // Jitter before building the fixture: without it this suite's
                // spawn lands in the same millisecond as a parallel suite's.
                try await Task.sleep(for: .milliseconds(.random(in: 200...600)))

                let operation = try startStalledOperation()
                guard await operation.progress.waitForProgress(timeout: .seconds(8)) else {
                    await abandon(operation)
                    if attempt == 3 {
                        Issue.record(
                            """
                            fixture never reported progress across 3 attempts; \
                            spawn is colliding with a parallel suite's spawn (the \
                            stdin-EOF starvation described in the suite doc) or \
                            the fixture is not starting at all
                            """)
                    }
                    continue
                }
                try await verifyQuitBackstopEnds(operation)
                return
            }
        }
    }

    // MARK: - One stalled operation

    private struct StalledOperation {
        let fixture: ManagedExtractorOperationFixture
        let task: Task<ManagedExtractorProcessResult, Error>
        let progress: FirstProgressLatch
    }

    /// Builds the fixture and starts the real executor against it. The task
    /// is never cancelled on the success path: the quit backstop, not a
    /// cooperative cancellation path, must end the operation. A construction
    /// failure throws to the test — nothing has started, so nothing needs
    /// teardown and a retry would not help.
    private func startStalledOperation() throws -> StalledOperation {
        let fixture = try ManagedExtractorOperationFixture(
            mode: "stall",
            maximumDurationMilliseconds: 60_000)
        let progress = FirstProgressLatch()
        let task = Task {
            try await ManagedExtractorProcessExecutor().execute(
                fixture.operation,
                onFrame: { progress.note($0) })
        }
        return StalledOperation(fixture: fixture, task: task, progress: progress)
    }

    /// Cancels a stalled attempt and reaps it, so the next attempt starts
    /// from a clean registry and no abandoned child keeps another suite's
    /// stdin pipe open.
    private func abandon(_ operation: StalledOperation) async {
        operation.task.cancel()
        do {
            _ = try await operation.task.value
        } catch {
            // Any error is fine here: cancellation reaps the group.
        }
        operation.fixture.cleanup()
    }

    /// The whole assertion sequence against one mid-run stalled operation.
    private func verifyQuitBackstopEnds(_ operation: StalledOperation) async throws {
        defer { operation.fixture.cleanup() }

        // The handle registers its group at spawn, before the process can
        // emit any frame, so the observed progress frame proves our group
        // is registered and mid-run. (The caller already awaited it.)
        guard let groupLeaderPID = await soleRegisteredGroup(timeout: .seconds(30)) else {
            operation.task.cancel()
            do {
                _ = try await operation.task.value
                Issue.record("expected a cancellation error from the executor task")
            } catch {
                // Fine: the contention failure is the recorded problem, and
                // cancellation reaps our group.
            }
            Issue.record(
                """
                the registry never drained to exactly this test's group within 30 s \
                (parallel suites keep registering fixture groups); refusing to \
                sweep the shared registry while other owned groups are in flight
                """)
            return
        }

        let outcome = try await quitBackstopOutcome()
        #expect(outcome.terminatedGroupCount == 1)

        // The executor sees its own process die by signal — the in-band
        // proof that the group really died, not just that a signal was sent.
        do {
            _ = try await operation.task.value
            Issue.record("expected processTermination, but the operation completed")
        } catch let error as ManagedExtractorProcessError {
            guard case .processTermination(.signaled, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
        }

        // The handle deregisters at observed leader exit.
        let deregistered = await waitForDeregistration(of: groupLeaderPID)
        #expect(deregistered, "group leader \(groupLeaderPID) stayed registered after the sweep")
    }

    // MARK: - Helpers

    /// Returns the single registered leader pid once the registry holds
    /// exactly one entry, or nil if the contention never settles.
    private func soleRegisteredGroup(timeout: Duration) async -> Int32? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let registered = OwnedProcessGroupRegistry.registeredProcessIDs
            if registered.count == 1 { return registered[0] }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return nil }
        }
        return nil
    }

    /// Bounded async retry — never a blocking sleep (#1051). Mirrors the
    /// helper in OwnedProcessGroupRegistryTests.
    private func waitForDeregistration(
        of processID: Int32,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if OwnedProcessGroupRegistry.registeredProcessIDs.contains(processID) == false {
                return true
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }
        return OwnedProcessGroupRegistry.registeredProcessIDs.contains(processID) == false
    }

    /// Runs the real quit backstop off the cooperative pool and races it
    /// against a timeout. The backstop sleeps synchronously by design — it
    /// is a quit-path API — so it must not park a cooperative-pool thread;
    /// the race turns a pathological hang into a fast, diagnosed failure
    /// instead (#1051).
    private func quitBackstopOutcome() async throws
        -> OwnedProcessGroupRegistry.TerminationOutcome {
        try await withThrowingTaskGroup(
            of: OwnedProcessGroupRegistry.TerminationOutcome.self
        ) { group in
            group.addTask {
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<
                        OwnedProcessGroupRegistry.TerminationOutcome, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            returning: OwnedProcessGroupRegistry.terminateAllOwnedGroups(
                                gracePeriod: .milliseconds(300)))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw QuitBackstopStalled()
            }
            guard let outcome = try await group.next() else {
                throw QuitBackstopStalled()
            }
            group.cancelAll()
            return outcome
        }
    }
}

/// The quit backstop ran far past its 300 ms grace period — it hung.
private struct QuitBackstopStalled: Error, CustomStringConvertible {
    var description: String { "the quit backstop did not finish within 10 s" }
}

/// Latches the first progress frame from the fixture. Any frame proves the
/// spawn completed and the group is registered; progress specifically proves
/// the operation is mid-run, not failing or completing.
private final class FirstProgressLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    func note(_ frame: ExtractorProtocolFrame) {
        guard case .progress = frame else { return }
        lock.withLock { observed = true }
    }

    func waitForProgress(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isObserved == false {
            if clock.now >= deadline { return false }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return isObserved }
        }
        return true
    }

    private var isObserved: Bool { lock.withLock { observed } }
}
