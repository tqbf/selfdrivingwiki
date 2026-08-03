import Foundation
import Testing
@testable import WikiFSTypes

/// This target links only WikiFSTypes. Its recorder is the sole signal seam.
struct ProcessSignalSafetySeamTests {
    private final class SignalRecorder {
        private(set) var processIDs: [Int32] = []

        func record(processID: Int32, signal _: Int32) -> Int32 {
            processIDs.append(processID)
            return 0
        }
    }

    @Test(arguments: ["", " ", "0", "1", "12x", "12\n4"])
    func invalidPIDFileContentsRefuseWithoutUsingTheSeam(_ contents: String) throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signalFromPIDFile(
            contents,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .refused(.invalidPIDFileContents))
        #expect(recorder.processIDs.isEmpty)
    }

    @Test func sentinelPIDRefusesWithoutUsingTheSeam() throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signalFromPIDFile(
            "-1",
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .refused(.invalidPIDFileContents))
        #expect(recorder.processIDs.isEmpty)
    }

    @Test func stalePIDRefusesWithoutUsingTheSeam() throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: nil,
            signal: recorder.record)

        #expect(outcome == .refused(.identityUnavailable))
        #expect(recorder.processIDs.isEmpty)
    }

    @Test func reusedPIDRefusesWithoutUsingTheSeam() throws {
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
        #expect(recorder.processIDs.isEmpty)
    }

    @Test func nonChildPIDRefusesWithoutUsingTheSeam() throws {
        let recorder = SignalRecorder()
        let expected = try identity()
        let differentParent = try positivePID(101)

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: differentParent,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .refused(.parentMismatch))
        #expect(recorder.processIDs.isEmpty)
    }

    @Test func verifiedChildUsesOnlyTheInjectedRecorder() throws {
        let recorder = SignalRecorder()
        let expected = try identity()

        let outcome = ProcessSignalSafety.signal(
            processID: expected.processID,
            expectedIdentity: expected,
            expectedParentProcessID: expected.parentProcessID,
            observedIdentity: expected,
            signal: recorder.record)

        #expect(outcome == .sent(result: 0))
        #expect(recorder.processIDs == [expected.processID.rawValue])
    }

    @Test func validationModuleAndFocusedTestTargetHaveNoSyscallPath() throws {
        let root = repositoryRoot()
        let validationSource = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSTypes/ProcessSignalSafety.swift"),
            encoding: .utf8)
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let syscallName = "kil" + "l("

        #expect(validationSource.contains(syscallName) == false)
        #expect(validationSource.contains("signal: (Int32, Int32) -> Int32") == true)

        let targetStart = try #require(manifest.range(of: "name: \"ProcessSignalSafetySeamTests\""))
        let targetTail = manifest[targetStart.lowerBound...]
        let targetEnd = try #require(targetTail.range(of: "        ),"))
        let target = String(targetTail[..<targetEnd.lowerBound])
        #expect(target.contains("dependencies: [\"WikiFSTypes\"]") == true)
        #expect(target.contains("WikiFSCore") == false)
        #expect(target.contains("DynamicRendererPRSeriesAudit") == false)
    }

    private func positivePID(_ rawValue: Int32) throws -> ProcessSignalSafety.PositivePID {
        try #require(ProcessSignalSafety.PositivePID(rawValue: rawValue))
    }

    private func identity(
        processID: Int32 = 42,
        parentProcessID: Int32 = 100,
        startTime: UInt64 = 100
    ) throws -> ProcessSignalSafety.Identity {
        ProcessSignalSafety.Identity(
            processID: try positivePID(processID),
            parentProcessID: try positivePID(parentProcessID),
            startTime: .init(seconds: startTime, microseconds: 0))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
