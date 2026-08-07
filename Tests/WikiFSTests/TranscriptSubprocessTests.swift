import Foundation
import Testing
@testable import WikiFSCore

struct TranscriptSubprocessTests {
    private final class SignalRecorder {
        private(set) var processIDs: [Int32] = []

        func record(processID: Int32, signal _: Int32) -> Int32 {
            processIDs.append(processID)
            return 0
        }
    }

    @Test func staleIdentityIsRefusedWithoutSignalling() throws {
        let registry = TranscriptSubprocess.ProcessRegistry()
        let expected = try identity(startTime: 100)
        let reused = try identity(startTime: 101)
        let recorder = SignalRecorder()

        registry.track(expected)
        registry.terminateAllForTesting(
            observeProcess: { _ in reused },
            sendSignal: recorder.record)

        #expect(recorder.processIDs.isEmpty)
    }

    @Test func verifiedIdentityIsSignalled() throws {
        let registry = TranscriptSubprocess.ProcessRegistry()
        let expected = try identity(startTime: 100)
        let recorder = SignalRecorder()

        registry.track(expected)
        registry.terminateAllForTesting(
            observeProcess: { _ in expected },
            sendSignal: recorder.record)

        #expect(recorder.processIDs == [expected.processID.rawValue])
    }

    private func identity(startTime: UInt64) throws -> ProcessSignalSafety.Identity {
        let processID = try #require(ProcessSignalSafety.PositivePID(rawValue: 42))
        let parentProcessID = try #require(
            ProcessSignalSafety.PositivePID(rawValue: ProcessInfo.processInfo.processIdentifier))
        return ProcessSignalSafety.Identity(
            processID: processID,
            parentProcessID: parentProcessID,
            startTime: .init(seconds: startTime, microseconds: 0))
    }
}
