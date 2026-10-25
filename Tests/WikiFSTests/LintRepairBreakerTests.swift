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

    // MARK: - Tier-2 (staged proposal) wiring (W5a §2)

    private let staged = LintRolloutSelection.stagedProposal(
        reason: "configuration not yet evaluated — repairs staged for your review")

    /// A clean breaker passes a staged selection through as tier 2: the run
    /// keeps proposing, and the tier is NOT repair-capable (nothing writes
    /// directly).
    @Test func cleanBreakerKeepsStagedSelectionAsTierTwo() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let authority = fixture.breaker.authority(after: staged, key: fixture.key)
        #expect(authority.tier == .stagedProposal)
        #expect(authority.isRepairCapable == false)
        #expect(authority.isProposalCapable)
        #expect(authority.approvalID == nil,
                "tier 2 has no approval row by definition")
        #expect(authority.reason?.contains("not yet evaluated") == true)
    }

    /// A tripped breaker pauses proposals for that configuration — plain
    /// report-only reason, tier 2 lost.
    @Test func trippedBreakerDegradesStagedSelectionToReportOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.breaker.record(.verificationFailure, for: fixture.key)
        fixture.breaker.record(.verificationFailure, for: fixture.key)
        let authority = fixture.breaker.authority(after: staged, key: fixture.key)
        #expect(authority.tier == .reportOnly)
        #expect(authority.isProposalCapable == false)
        #expect(authority.reason?.hasPrefix("proposals paused for this configuration") == true)
    }

    /// A missing breaker key demotes a staged selection too (local state can
    /// only reduce authority; "cannot consult" is "cannot stage").
    @Test func missingKeyDegradesStagedSelectionToReportOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let authority = fixture.breaker.authority(after: staged, key: nil)
        #expect(authority.tier == .reportOnly)
        #expect(authority.reason?.contains("breaker configuration unavailable") == true)
    }

    /// The tier-2 breaker key is constructed from the live pipeline digest +
    /// provider/model/effort tuple DIRECTLY — no approval row involved (tier
    /// 2 has none by definition). Two runs on the same configuration share
    /// one breaker file.
    @Test func tierTwoKeyResolvesWithoutApprovalRow() throws {
        let pipeline = LintAcceptanceManifest.Pipeline(
            promptSHA256: String(repeating: "1", count: 64),
            detectorRevision: LintPreflightReport.detectorRevision,
            fixtureDigest: String(repeating: "2", count: 64))
        let key = LintRepairBreakerKey(
            pipeline: pipeline, provider: "deepseek", model: "r1", effort: "low")
        #expect(key.provider == "deepseek")
        #expect(key.pipelineDigest == LintRepairBreakerKey.digest(of: pipeline))

        // The same tuple always names the same state file — one breaker per
        // configuration, regardless of any approval manifest content.
        let again = LintRepairBreakerKey(
            pipeline: pipeline, provider: "deepseek", model: "r1", effort: "low")
        #expect(again.stateFileName == key.stateFileName)
    }

    /// Two rejected staged proposals trip the breaker with the same
    /// thresholds as undos; the window counts them separately.
    @Test func twoUserRejectionsTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.breaker.recordUserRejected(for: fixture.key) == .clean)
        #expect(fixture.breaker.windowStatus(for: fixture.key).userRejections == 1)
        #expect(fixture.breaker.windowStatus(for: fixture.key).userUndos == 0)
        guard case .tripped(let reason) = fixture.breaker.recordUserRejected(for: fixture.key) else {
            Issue.record("a second rejection in the window must trip")
            return
        }
        #expect(reason.contains("2 staged proposals rejected"))
        let authority = fixture.breaker.authority(after: staged, key: fixture.key)
        #expect(authority.tier == .reportOnly,
                "a tripped breaker pauses proposals for the configuration")
    }

    /// Rejections and undos count in ONE shared window: a rejection plus an
    /// undo does NOT trip (each kind needs its own two).
    @Test func rejectionAndUndoDoNotTripEachOther() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.breaker.recordUserRejected(for: fixture.key)
        #expect(fixture.breaker.recordUserUndo(for: fixture.key) == .clean)
        let status = fixture.breaker.windowStatus(for: fixture.key)
        #expect(status.userRejections == 1 && status.userUndos == 1)
        #expect(status.isTripped == false)
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
