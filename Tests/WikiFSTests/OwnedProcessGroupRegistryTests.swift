import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// #1330: the quit-time backstop for owned process groups.
@Suite("Owned process group registry", .serialized, .timeLimit(.minutes(2)))
struct OwnedProcessGroupRegistryTests {
    /// Records what a termination pass did, with lock-protected state.
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        private var signalCalls: [(processID: Int32, signalNumber: Int32)] = []
        private var sleepDurations: [Duration] = []

        func recordSignal(processID: Int32, signalNumber: Int32) {
            lock.withLock { signalCalls.append((processID, signalNumber)) }
        }

        func recordSleep(_ duration: Duration) {
            lock.withLock { sleepDurations.append(duration) }
        }

        var signals: [(processID: Int32, signalNumber: Int32)] {
            lock.withLock { signalCalls }
        }

        var sleeps: [Duration] {
            lock.withLock { sleepDurations }
        }

        var sleepCount: Int {
            lock.withLock { sleepDurations.count }
        }
    }

    private func identity(processID: Int32) -> ProcessSignalSafety.Identity {
        ProcessSignalSafety.Identity(
            processID: ProcessSignalSafety.PositivePID(rawValue: processID)!,
            parentProcessID: ProcessSignalSafety.PositivePID(rawValue: 99)!,
            startTime: ProcessSignalSafety.StartTime(seconds: 1, microseconds: 0))
    }

    private func entry(processID: Int32) -> OwnedProcessGroupRegistry.Entry {
        OwnedProcessGroupRegistry.Entry(
            processID: processID,
            identity: identity(processID: processID),
            parentProcessID: ProcessSignalSafety.PositivePID(rawValue: 99)!)
    }

    /// A stubborn group survives the grace period as the same verified
    /// process: it gets SIGTERM and then SIGKILL. A group that dies inside
    /// the grace period gets SIGTERM only. A group that already ended or was
    /// pid-replaced gets nothing.
    @Test func quitTerminationSignalsVerifiedGroupsInOrder() async throws {
        let recorder = Recorder()
        // 101 ignores SIGTERM. 102 dies during the grace window. 103 is
        // already gone. 104's pid was recycled: the pinned identity says
        // start time 1, the observation now reports start time 2.
        let stubborn = entry(processID: 101)
        let graceful = entry(processID: 102)
        let ended = entry(processID: 103)
        let replaced = entry(processID: 104)
        for item in [stubborn, graceful, ended, replaced] {
            OwnedProcessGroupRegistry.register(item)
        }
        defer {
            for item in [stubborn, graceful, ended, replaced] {
                OwnedProcessGroupRegistry.deregister(processID: item.processID)
            }
        }

        let outcome = OwnedProcessGroupRegistry.terminateAllOwnedGroups(
            gracePeriod: .milliseconds(50),
            observe: { pid in
                switch pid.rawValue {
                case 103: return nil
                case 104:
                    return ProcessSignalSafety.Identity(
                        processID: pid,
                        parentProcessID: replaced.identity.parentProcessID,
                        startTime: .init(seconds: 2, microseconds: 0))
                case 102 where recorder.sleepCount > 0:
                    return nil
                default:
                    return ProcessSignalSafety.Identity(
                        processID: pid,
                        parentProcessID: ProcessSignalSafety.PositivePID(rawValue: 99)!,
                        startTime: .init(seconds: 1, microseconds: 0))
                }
            },
            signalGroup: { pid, signalNumber in
                recorder.recordSignal(processID: pid, signalNumber: signalNumber)
                return 0
            },
            sleep: { duration in recorder.recordSleep(duration) })

        #expect(outcome.terminatedGroupCount == 2)
        #expect(outcome.alreadyEndedGroupCount == 1)
        #expect(outcome.unverifiedGroupCount == 1)
        #expect(recorder.sleeps == [.milliseconds(50)])
        let signals = recorder.signals
        #expect(signals.count == 3)
        guard signals.count == 3 else { return }
        #expect(signals[0].processID == 101 && signals[0].signalNumber == SIGTERM)
        #expect(signals[1].processID == 102 && signals[1].signalNumber == SIGTERM)
        #expect(signals[2].processID == 101 && signals[2].signalNumber == SIGKILL)
    }

    /// An empty registry is the normal quit: no sleep, no signal.
    @Test func quitTerminationWithNoGroupsSleepsNothing() {
        let recorder = Recorder()
        let outcome = OwnedProcessGroupRegistry.terminateAllOwnedGroups(
            gracePeriod: .milliseconds(50),
            observe: { _ in nil },
            signalGroup: { pid, signalNumber in
                recorder.recordSignal(processID: pid, signalNumber: signalNumber)
                return 0
            },
            sleep: { duration in recorder.recordSleep(duration) })

        #expect(outcome == OwnedProcessGroupRegistry.TerminationOutcome(
            terminatedGroupCount: 0,
            alreadyEndedGroupCount: 0,
            unverifiedGroupCount: 0))
        #expect(recorder.sleeps.isEmpty)
        #expect(recorder.signals.isEmpty)
    }

    /// Deregistration removes a group from quit termination. This is the
    /// observed-exit path: a reaped leader can no longer be signaled.
    @Test func deregisteredGroupsAreNotSignaled() {
        let recorder = Recorder()
        let group = entry(processID: 201)
        OwnedProcessGroupRegistry.register(group)
        OwnedProcessGroupRegistry.deregister(processID: 201)

        let outcome = OwnedProcessGroupRegistry.terminateAllOwnedGroups(
            gracePeriod: .milliseconds(1),
            observe: { _ in identity(processID: 201) },
            signalGroup: { pid, signalNumber in
                recorder.recordSignal(processID: pid, signalNumber: signalNumber)
                return 0
            },
            sleep: { duration in recorder.recordSleep(duration) })

        #expect(outcome.terminatedGroupCount == 0)
        #expect(recorder.signals.isEmpty)
    }

    /// A real launched group is registered, killed through the registry's
    /// verified group-kill primitive, and deregistered at observed exit —
    /// the exact sequence a daemon quit relies on when its worker
    /// settlement never ran (#1330).
    ///
    /// This test deliberately does NOT call `terminateAllOwnedGroups()`: the
    /// registry is process-global, parallel suites in this target register
    /// their own fixture groups, and a global sweep would kill them.
    @Test func launchedGroupIsRegisteredKilledAndDeregistered() async throws {
        let handle = try RaceFreeProcessGroupRunner.launch(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: [:],
                currentDirectoryURL: nil,
                standardInput: Data(),
                stdoutLimit: 1_024,
                stderrLimit: 1_024))
        #expect(OwnedProcessGroupRegistry.registeredProcessIDs.contains(handle.processID))

        _ = OwnedProcessGroupRegistry.killVerifiedProcessGroup(
            groupLeaderPID: handle.processID,
            signalNumber: SIGKILL)

        // The group died by signal. Bounded async wait: the runner reaps the
        // leader on its exit source and deregisters right after.
        let exited = await waitForDeregistration(of: handle.processID)
        #expect(exited)
        let result = try await handle.result(timeout: .seconds(10))
        guard case .signaled = result.terminationCause else {
            Issue.record("expected .signaled, got \(result.terminationCause)")
            return
        }
    }

    /// Bounded async retry. Never blocks a cooperative-pool thread with a
    /// synchronous sleep (house rule: #1051).
    private func waitForDeregistration(of processID: Int32, attempts: Int = 50) async -> Bool {
        for _ in 0..<attempts {
            if OwnedProcessGroupRegistry.registeredProcessIDs.contains(processID) == false {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return OwnedProcessGroupRegistry.registeredProcessIDs.contains(processID) == false
    }
}
