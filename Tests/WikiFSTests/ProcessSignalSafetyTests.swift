#if os(macOS)
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import WikiFSCore

struct ProcessSignalSafetyTests {
    /// The fake seam proves that refused cleanup never invokes a real signal.
    private final class SignalRecorder {
        private var calls: [(Int32, Int32)] = []

        func record(processID: Int32, signal: Int32) -> Int32 {
            calls.append((processID, signal))
            return 0
        }

        var recordedCalls: [(Int32, Int32)] { calls }
    }

    @Test(arguments: ["", " ", "\n", "-1", "0", "1", "12x", "12\n4"])
    func invalidOrPartialPIDFileContentsNeverInvokeSignal(_ contents: String) throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signalFromPIDFile(
            contents,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .refused(.invalidPIDFileContents))
        #expect(recorder.recordedCalls.isEmpty)
    }

    @Test func validPIDFileContentSignalsOnlyMatchingCurrentChildIdentity() throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signalFromPIDFile(
            "42\n",
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .sent(result: 0))
        #expect(recorder.recordedCalls.count == 1)
        #expect(recorder.recordedCalls.first?.0 == 42)
        #expect(recorder.recordedCalls.first?.1 == SIGKILL)
    }

    @Test func staleOrReusedPIDNeverInvokesSignal() throws {
        let recorder = SignalRecorder()
        let expected = try identity()
        let reused = try identity(startTime: 101)

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: reused,
            signal: recorder.record)

        #expect(outcome == .refused(.identityMismatch))
        #expect(recorder.recordedCalls.isEmpty)
    }

    @Test func nonDescendantPIDNeverInvokesSignal() throws {
        let recorder = SignalRecorder()
        let expected = try identity()
        let unrelatedChild = try identity(processID: 43)

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: unrelatedChild,
            signal: recorder.record)

        #expect(outcome == .refused(.identityMismatch))
        #expect(recorder.recordedCalls.isEmpty)
    }

    @Test func candidatePIDMismatchNeverInvokesSignal() throws {
        let recorder = SignalRecorder()
        let expected = try identity()
        let mismatchedCandidate = try #require(ProcessSignalSafety.PositivePID(rawValue: 43))

        let outcome = ProcessSignalSafety.signal(
            processID: mismatchedCandidate,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .refused(.identityMismatch))
        #expect(recorder.recordedCalls.isEmpty)
    }

    @Test func unavailableCurrentIdentityNeverInvokesSignal() throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: nil,
            signal: recorder.record)

        #expect(outcome == .refused(.identityUnavailable))
        #expect(recorder.recordedCalls.isEmpty)
    }

    @Test func parentMismatchNeverInvokesSignal() throws {
        let recorder = SignalRecorder()
        let expected = try identity()
        let wrongParent = try #require(ProcessSignalSafety.PositivePID(rawValue: 101))

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: wrongParent,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .refused(.parentMismatch))
        #expect(recorder.recordedCalls.isEmpty)
    }

    private func identity(
        processID: Int32 = 42,
        parentProcessID: Int32 = 100,
        startTime: UInt64 = 100
    ) throws -> ProcessSignalSafety.Identity {
        ProcessSignalSafety.Identity(
            processID: try #require(ProcessSignalSafety.PositivePID(rawValue: processID)),
            parentProcessID: try #require(ProcessSignalSafety.PositivePID(rawValue: parentProcessID)),
            startTime: .init(seconds: startTime, microseconds: 0))
    }
}
#endif
