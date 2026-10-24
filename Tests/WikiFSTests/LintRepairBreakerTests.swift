#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine

/// W2a §1/§6: the local lint repair circuit breaker. Local state can only
/// REDUCE authority — every damaged, forged, or unreachable state demotes.
struct LintRepairBreakerTests {

    private struct Fixture {
        let container: URL
        let breaker: LintRepairBreaker
        let key = LintRepairBreakerKey(
            pipelineDigest: "pipeline-a", provider: "anthropic", model: "claude-opus", effort: "high")

        init() throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("lint-breaker-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let resolved = container
            breaker = LintRepairBreaker(containerResolver: { resolved })
        }

        var stateFile: URL {
            container
                .appendingPathComponent(LintRepairBreaker.directoryName, isDirectory: true)
                .appendingPathComponent(key.stateFileName, isDirectory: false)
        }

        func cleanUp() {
            do {
                try FileManager.default.removeItem(at: container)
            } catch {
                // Temp-directory cleanup only; a leftover dir cannot affect
                // another test (each uses its own UUID path).
            }
        }
    }

    private let approved = LintRolloutSelection.repairAuthorized(approvalID: "row-1")

    // MARK: - Trip rules

    @Test func twoVerificationFailuresTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.breaker.record(.verificationFailure, for: fixture.key) == .clean)
        guard case .tripped(let reason) = fixture.breaker.record(.verificationFailure, for: fixture.key) else {
            Issue.record("a second verification failure in the window must trip")
            return
        }
        #expect(reason.contains("2 verification failures"))
        let authority = fixture.breaker.authority(after: approved, key: fixture.key)
        #expect(authority.tier == .breakerDemoted)
        #expect(authority.approvalID == LintApprovalID(rawValue: "row-1"),
                "a demoted run still names the approval row it would have used")
        #expect(authority.reason?.hasPrefix("circuit breaker tripped: ") == true)
        #expect(authority.isRepairCapable == false)
    }

    @Test func twoUserUndosTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.breaker.recordUserUndo(for: fixture.key) == .clean)
        guard case .tripped(let reason) = fixture.breaker.recordUserUndo(for: fixture.key) else {
            Issue.record("a second undo in the window must trip")
            return
        }
        #expect(reason.contains("2 user undos"))
        #expect(fixture.breaker.authority(after: approved, key: fixture.key).tier == .breakerDemoted)
    }

    @Test func cleanOutcomesNeverTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for _ in 0..<(LintRepairBreaker.windowSize + 3) {
            #expect(fixture.breaker.record(.clean, for: fixture.key) == .clean)
        }
        #expect(fixture.breaker.consult(fixture.key) == .clean)
        let authority = fixture.breaker.authority(after: approved, key: fixture.key)
        #expect(authority == .shippedApproval(LintApprovalID(rawValue: "row-1")))
    }

    /// The window keeps only the last `windowSize` outcomes: a failure that
    /// rolled out of the window no longer counts toward a trip.
    @Test func windowRolls() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.breaker.record(.verificationFailure, for: fixture.key)
        for _ in 0..<LintRepairBreaker.windowSize {
            fixture.breaker.record(.clean, for: fixture.key)
        }
        #expect(fixture.breaker.record(.verificationFailure, for: fixture.key) == .clean,
                "the first failure rolled out of the window")
        if case .tripped = fixture.breaker.record(.verificationFailure, for: fixture.key) {
            // Expected: two failures inside the window.
        } else {
            Issue.record("two failures inside the window must trip")
        }
    }

    @Test func reportOnlySelectionPassesThroughUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let authority = fixture.breaker.authority(
            after: .reportOnly(reason: "not in the approved matrix"), key: fixture.key)
        #expect(authority == .reportOnly(reason: "not in the approved matrix"))
    }

    // MARK: - Reset

    /// An app update that changes the pipeline discards the old state.
    @Test func pipelineChangeResets() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.breaker.record(.verificationFailure, for: fixture.key)
        fixture.breaker.record(.verificationFailure, for: fixture.key)
        #expect(fixture.breaker.consult(fixture.key) != .clean)

        let updated = LintRepairBreakerKey(
            pipelineDigest: "pipeline-b", provider: fixture.key.provider,
            model: fixture.key.model, effort: fixture.key.effort)
        #expect(updated.stateFileName == fixture.key.stateFileName,
                "the same configuration reuses its file, so the reset happens in place")
        #expect(fixture.breaker.consult(updated) == .clean)
        #expect(FileManager.default.fileExists(atPath: fixture.stateFile.path) == false,
                "the stale-pipeline state is discarded")
        // Fresh state: one failure under the new pipeline does not trip.
        #expect(fixture.breaker.record(.verificationFailure, for: updated) == .clean)
    }

    // MARK: - Damaged or missing state demotes

    @Test func corruptStateFileDemotes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fixture.stateFile)

        #expect(fixture.breaker.consult(fixture.key) == .tripped(reason: "breaker state unreadable"))
        let authority = fixture.breaker.authority(after: approved, key: fixture.key)
        #expect(authority.tier == .breakerDemoted)
        #expect(authority.reason == "circuit breaker tripped: breaker state unreadable")
        // A record never heals damaged state into a clean one.
        #expect(fixture.breaker.record(.clean, for: fixture.key) == .tripped(reason: "breaker state unreadable"))
        #expect(try Data(contentsOf: fixture.stateFile) == garbage)
    }

    /// A forged file with an unknown schema is unreadable state, not a
    /// clean one.
    @Test func unknownSchemaDemotes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let forged = """
        {"schema": 99, "pipelineDigest": "pipeline-a", "provider": "anthropic",
         "model": "claude-opus", "effort": "high", "outcomes": []}
        """
        try Data(forged.utf8).write(to: fixture.stateFile)
        #expect(fixture.breaker.consult(fixture.key) == .tripped(reason: "breaker state unreadable"))
    }

    @Test func missingAppGroupDemotes() {
        struct NoAppGroup: Error {}
        let breaker = LintRepairBreaker(containerResolver: { throw NoAppGroup() })
        let key = LintRepairBreakerKey(pipelineDigest: "p", provider: "a", model: "m", effort: "e")
        guard case .tripped(let reason) = breaker.consult(key) else {
            Issue.record("an unresolvable App Group must demote, never authorize")
            return
        }
        #expect(reason.contains("App Group container unavailable"))
        #expect(breaker.authority(after: approved, key: key).tier == .breakerDemoted)
        if case .clean = breaker.record(.clean, for: key) {
            Issue.record("recording without an App Group must not report clean")
        }
    }

    @Test func missingKeyDemotes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let authority = fixture.breaker.authority(after: approved, key: nil)
        #expect(authority.tier == .breakerDemoted)
        #expect(authority.reason?.contains("breaker configuration unavailable") == true)
    }

    // MARK: - File naming

    @Test func stateFileNameIsSanitizedAndDeterministic() {
        let key = LintRepairBreakerKey(
            pipelineDigest: "p", provider: "open/router", model: "a:b c", effort: "high")
        let name = key.stateFileName
        #expect(name == key.stateFileName)
        #expect(name.hasSuffix(".json"))
        #expect(name.contains("/") == false && name.contains(":") == false && name.contains(" ") == false)
        // Two configurations whose readable parts sanitize alike stay apart.
        let lookalike = LintRepairBreakerKey(
            pipelineDigest: "p", provider: "open:router", model: "a:b c", effort: "high")
        #expect(lookalike.stateFileName != name)
        // The pipeline is not part of the name (see pipelineChangeResets).
        let otherPipeline = LintRepairBreakerKey(
            pipelineDigest: "q", provider: "open/router", model: "a:b c", effort: "high")
        #expect(otherPipeline.stateFileName == name)
    }

    @Test func pipelineDigestIsStableAndSensitive() {
        let pipeline = LintAcceptanceManifest.Pipeline(
            promptSHA256: "aa", detectorRevision: "r1", fixtureDigest: "ff")
        let digest = LintRepairBreakerKey.digest(of: pipeline)
        #expect(digest == LintRepairBreakerKey.digest(of: pipeline))
        #expect(digest != LintRepairBreakerKey.digest(of: LintAcceptanceManifest.Pipeline(
            promptSHA256: "aa", detectorRevision: "r2", fixtureDigest: "ff")))
    }
}
#endif
