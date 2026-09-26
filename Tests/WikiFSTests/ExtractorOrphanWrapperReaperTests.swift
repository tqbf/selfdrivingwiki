import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// #1330: deciding which processes are orphaned extractor wrappers.
@Suite("Extractor orphan wrapper reaper", .serialized, .timeLimit(.minutes(2)))
struct ExtractorOrphanWrapperReaperTests {
    private let operationsRoot = "/tmp/orphan-reaper-fixture/extractors/v1/operations"
    private let currentProcessID: Int32 = 5_000
    private let currentUserID: UInt32 = 501
    private let currentSession = ExtractorStagingID(
        rawValue: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    private func candidate(
        processID: Int32,
        processGroupID: Int32 = 6_000,
        userID: UInt32 = 501,
        arguments: String
    ) -> ExtractorOrphanWrapperCandidate {
        ExtractorOrphanWrapperCandidate(
            processID: processID,
            processGroupID: processGroupID,
            userID: userID,
            arguments: Data((arguments + "\0").utf8))
    }

    private func decisions(
        _ candidates: [ExtractorOrphanWrapperCandidate],
        ownerIsAlive: @escaping (Int32) -> Bool = { _ in false }
    ) -> [ExtractorOrphanWrapperReaper.ReapDecision] {
        ExtractorOrphanWrapperReaper.reapDecisions(
            operationsRootPath: operationsRoot,
            candidates: candidates,
            currentProcessID: currentProcessID,
            currentUserID: currentUserID,
            currentSessionID: currentSession,
            ownerIsAlive: ownerIsAlive)
    }

    // MARK: - Orphans are reaped

    /// The wrapper command line names its operation directory, and the
    /// owning daemon pid is dead: reap the process group.
    @Test func deadOwnerWrapperIsReaped() {
        let decision = decisions([
            candidate(
                processID: 7_001,
                arguments: "/usr/local/bin/uv run --script \(operationsRoot)/daemon/4242-0f0e0d0c-1111/home/x")
        ]).single
        #expect(decision == ExtractorOrphanWrapperReaper.ReapDecision(
            processID: 7_001,
            processGroupID: 6_000,
            ownerProcessID: 4_242,
            role: .daemon))
    }

    /// The operation path in an environment string counts too: HOME points
    /// inside the operation directory the dead daemon created.
    @Test func deadOwnerReferencedOnlyInEnvironmentIsReaped() {
        let decision = decisions([
            candidate(
                processID: 7_002,
                arguments: "HOME=\(operationsRoot)/app/9292-abcdef01-2222/home")
        ]).single
        #expect(decision?.role == .app)
        #expect(decision?.ownerProcessID == 9_292)
    }

    /// Pid reuse: this process holds the owner pid, but the session belongs
    /// to an earlier lifetime with that pid. The wrapper is an orphan.
    @Test func ownPidWithDifferentSessionIsReaped() {
        let decision = decisions([
            candidate(
                processID: 7_003,
                arguments: "\(operationsRoot)/daemon/\(currentProcessID)-99999999-8888/pkg")
        ]).single
        #expect(decision?.ownerProcessID == currentProcessID)
    }

    /// Two dead-owner references in one blob still yield one decision per
    /// process: the process dies once.
    @Test func oneDecisionPerProcess() {
        let result = decisions([
            candidate(
                processID: 7_004,
                arguments: "\(operationsRoot)/daemon/11-11111111-1111/a \(operationsRoot)/test/22-22222222-2222/b")
        ])
        #expect(result.count == 1)
    }

    // MARK: - Everything else is kept

    @Test func liveOwnerWrapperIsKept() {
        #expect(decisions(
            [candidate(processID: 7_005, arguments: "\(operationsRoot)/daemon/4242-0f0e0d0c-1111/x")],
            ownerIsAlive: { _ in true }
        ).isEmpty)
    }

    @Test func foreignUserProcessIsKept() {
        #expect(decisions(
            [candidate(processID: 7_006, userID: 502, arguments: "\(operationsRoot)/daemon/4242-0f0e0d0c-1111/x")]
        ).isEmpty)
    }

    @Test func callingProcessIsKept() {
        #expect(decisions(
            [candidate(processID: currentProcessID, arguments: "\(operationsRoot)/daemon/4242-0f0e0d0c-1111/x")]
        ).isEmpty)
    }

    /// This process's OWN current session is live by definition, even though
    /// the owner pid equals the caller's pid.
    @Test func ownCurrentSessionIsKept() {
        #expect(decisions(
            [candidate(processID: 7_007, arguments: "\(operationsRoot)/daemon/\(currentProcessID)-\(currentSession.rawValue)/x")]
        ).isEmpty)
    }

    @Test func invalidProcessGroupIsKept() {
        #expect(decisions(
            [candidate(processID: 7_008, processGroupID: 1, arguments: "\(operationsRoot)/daemon/4242-0f0e0d0c-1111/x")]
        ).isEmpty)
    }

    @Test func malformedSessionNameIsKept() {
        #expect(decisions(
            [candidate(processID: 7_009, arguments: "\(operationsRoot)/daemon/not-a-pid-session/x")]
        ).isEmpty)
    }

    @Test func unknownRoleIsKept() {
        #expect(decisions(
            [candidate(processID: 7_010, arguments: "\(operationsRoot)/cron/4242-0f0e0d0c-1111/x")]
        ).isEmpty)
    }

    @Test func unrelatedPathIsKept() {
        #expect(decisions(
            [candidate(processID: 7_011, arguments: "/usr/local/bin/uv run --script /somewhere/else/tool")]
        ).isEmpty)
    }

    /// Containment is byte-level: only this container's operations root
    /// matches, and a different container's operation path never does. The
    /// dead-owner rule — not path anchoring — is what keeps a match safe.
    @Test func differentOperationsRootIsKept() {
        #expect(decisions(
            [candidate(processID: 7_012, arguments: "/tmp/another-container/extractors/v1/operations/daemon/4242-0f0e0d0c-1111/x")]
        ).isEmpty)
    }

    // MARK: - Integration: a real orphan dies

    /// A real process group whose arguments reference a dead owner's
    /// operation path is killed by the sweep, and the quit registry drops it
    /// at observed exit. Owner pid 9_999_999 sits past the macOS pid range,
    /// so the liveness probe always reads it as dead.
    @Test func sweepKillsARealOrphanWrapperGroup() async throws {
        let fakeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-reaper-\(UUID().uuidString)", isDirectory: true)
        let deadOwnerPath = (fakeRoot.path + "/extractors/v1/operations")
            + "/daemon/9999999-33333333-4444/package/bin/tool"
        let handle = try RaceFreeProcessGroupRunner.launch(
            .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: [deadOwnerPath],
                environment: [:],
                currentDirectoryURL: nil,
                standardInput: Data(),
                stdoutLimit: 1_024,
                stderrLimit: 1_024))
        #expect(OwnedProcessGroupRegistry.registeredProcessIDs.contains(handle.processID))

        let report = ExtractorOrphanWrapperSweeper.reapOrphanWrappers(
            operationsRoot: URL(
                fileURLWithPath: fakeRoot.path + "/extractors/v1/operations",
                isDirectory: true),
            currentSessionID: currentSession)

        #expect(report.reapedProcessGroupCount >= 1)
        #expect(report.reapedProcessIDs.contains(handle.processID))
        // The runner reaps and deregisters the leader after the SIGKILL.
        let exited = await waitForDeregistration(of: handle.processID)
        #expect(exited)
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

private extension Array {
    /// The single element, or nil for zero or many. Tests use this to make
    /// "exactly one decision" failures legible.
    var single: Element? {
        count == 1 ? first : nil
    }
}
