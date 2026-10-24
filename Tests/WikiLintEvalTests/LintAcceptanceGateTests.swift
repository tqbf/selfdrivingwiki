import Foundation
import Testing
import WikiFSCore

/// AC.14: the rollout gate matches the SHIPPED approval manifest
/// structurally. Only an enabled, valid manifest whose pipeline equals the
/// build's and whose matrix holds the exact provider/model/effort row
/// authorizes repairs; everything else selects report-only, never a throw.
struct LintAcceptanceGateTests {

    // MARK: - Fixtures

    private let pipeline = LintAcceptanceManifest.Pipeline(
        promptSHA256: String(repeating: "a", count: 64),
        detectorRevision: LintPreflightReport.detectorRevision,
        fixtureDigest: String(repeating: "b", count: 64))

    private let evidence = LintAcceptanceManifest.Evidence(
        reportSHA256: String(repeating: "c", count: 64),
        rubricReviewer: "operator",
        decidedAt: Date(timeIntervalSince1970: 1_790_000_000),
        bailTrials: "3/3")

    private func row(revision: String? = "20260101") -> LintAcceptanceManifest.Approval {
        LintAcceptanceManifest.Approval(
            id: "anthropic-sonnet-low-1", provider: "anthropic", model: "claude-sonnet",
            effort: "low", evaluatedRevision: revision, acceptanceKeySHA256: nil)
    }

    private func manifest(
        approvals: [LintAcceptanceManifest.Approval]? = nil,
        defaultReportOnly: Bool = false
    ) -> LintAcceptanceManifest {
        let rows = approvals ?? [row()]
        return LintAcceptanceManifest(
            pipeline: pipeline, evidence: rows.isEmpty ? nil : evidence,
            approvals: rows, defaultReportOnly: defaultReportOnly)
    }

    private func components(
        provider: String = "anthropic", model: String = "claude-sonnet",
        revision: String? = "20260101", effort: String = "low",
        pipeline override: LintAcceptanceManifest.Pipeline? = nil
    ) -> LintAcceptanceKey.Components {
        let used = override ?? pipeline
        return LintAcceptanceKey.Components(
            provider: provider, model: model, modelRevision: revision, effort: effort,
            promptSHA256: used.promptSHA256, detectorRevision: used.detectorRevision,
            fixtureDigest: used.fixtureDigest)
    }

    private func reason(_ selection: LintRolloutSelection) -> String? {
        if case .reportOnly(let reason) = selection { return reason }
        return nil
    }

    // MARK: - Matching

    @Test func matchingRowAuthorizesWithItsID() {
        let gate = LintAcceptanceGate(manifest: manifest())
        #expect(gate.selection(for: components())
            == .repairAuthorized(approvalID: "anthropic-sonnet-low-1"))
    }

    @Test(arguments: [
        ("openai", "claude-sonnet", "low"),
        ("anthropic", "claude-opus", "low"),
        ("anthropic", "claude-sonnet", "high"),
    ])
    func unacceptedConfigurationIsReportOnly(provider: String, model: String, effort: String) throws {
        let gate = LintAcceptanceGate(manifest: manifest())
        let selection = gate.selection(for: components(
            provider: provider, model: model, effort: effort))
        let why = try #require(reason(selection))
        #expect(why.contains("not in the approved matrix"))
    }

    @Test func defaultReportOnlyWinsOverMatchingRows() throws {
        let gate = LintAcceptanceGate(manifest: manifest(defaultReportOnly: true))
        let why = try #require(reason(gate.selection(for: components())))
        #expect(why.contains("approval pending"))
    }

    @Test(arguments: ["prompt", "detector", "fixtures"])
    func changedPipelineComponentIsReportOnly(component: String) throws {
        let changed = LintAcceptanceManifest.Pipeline(
            promptSHA256: component == "prompt" ? String(repeating: "d", count: 64) : pipeline.promptSHA256,
            detectorRevision: component == "detector" ? "lint-preflight-v999" : pipeline.detectorRevision,
            fixtureDigest: component == "fixtures" ? String(repeating: "e", count: 64) : pipeline.fixtureDigest)
        let gate = LintAcceptanceGate(manifest: manifest())
        let why = try #require(reason(gate.selection(for: components(pipeline: changed))))
        #expect(why.contains("pipeline changed"))
    }

    @Test func revisionMismatchIsReportOnlyWhenBothKnown() throws {
        let gate = LintAcceptanceGate(manifest: manifest())
        let why = try #require(reason(gate.selection(for: components(revision: "20260201"))))
        #expect(why.contains("model revision changed"))
    }

    /// Documented limitation: a revision missing on either side does not
    /// fail the match.
    @Test func missingRevisionOnEitherSideStillMatches() {
        let unrevisioned = LintAcceptanceGate(manifest: manifest(approvals: [row(revision: nil)]))
        #expect(unrevisioned.selection(for: components(revision: "20260201"))
            == .repairAuthorized(approvalID: "anthropic-sonnet-low-1"))
        let revisioned = LintAcceptanceGate(manifest: manifest())
        #expect(revisioned.selection(for: components(revision: nil))
            == .repairAuthorized(approvalID: "anthropic-sonnet-low-1"))
    }

    // MARK: - Missing / malformed manifests

    @Test(arguments: [
        "not json",
        #"{"manifestSchema":2}"#,
        #"{"manifestSchema":2,"pipeline":{"promptSHA256":"a","detectorRevision":"b","fixtureDigest":"c"},"evidence":null,"approvals":[{"id":"x"}],"defaultReportOnly":false}"#,
    ])
    func undecodableManifestIsReportOnly(json: String) throws {
        let gate = LintAcceptanceGate(manifestData: Data(json.utf8))
        let why = try #require(reason(gate.selection(for: components())))
        #expect(why.contains("missing or invalid"))
    }

    @Test func missingManifestIsReportOnly() throws {
        let gate = LintAcceptanceGate(unavailableReason: "resource not found")
        let why = try #require(reason(gate.selection(for: components())))
        #expect(why.contains("missing or invalid"))
    }

    @Test func structurallyInvalidManifestsAreReportOnly() throws {
        let invalid = [
            LintAcceptanceManifest(
                manifestSchema: 3, pipeline: pipeline, evidence: evidence,
                approvals: [row()], defaultReportOnly: false),
            LintAcceptanceManifest(
                pipeline: pipeline, evidence: nil, approvals: [row()], defaultReportOnly: false),
            LintAcceptanceManifest(
                pipeline: pipeline, evidence: evidence, approvals: [], defaultReportOnly: false),
            LintAcceptanceManifest(
                pipeline: pipeline, evidence: evidence,
                approvals: [LintAcceptanceManifest.Approval(
                    id: "x", provider: "anthropic", model: "claude-sonnet", effort: "low",
                    evaluatedRevision: nil, acceptanceKeySHA256: nil, authority: "root")],
                defaultReportOnly: false),
        ]
        for candidate in invalid {
            #expect(candidate.structuralProblem != nil)
            let why = try #require(reason(LintAcceptanceGate(manifest: candidate)
                .selection(for: components())))
            #expect(why.contains("missing or invalid"))
        }
    }

    /// The emitted form carries explicit nulls and round-trips.
    @Test func manifestRoundTripsWithExplicitNulls() throws {
        let empty = manifest(approvals: [])
        let text = String(decoding: try empty.encoded(), as: UTF8.self)
        #expect(text.contains(#""evidence" : null"#))
        #expect(try LintAcceptanceManifest.decode(try empty.encoded()) == empty)
        let full = manifest(approvals: [row(revision: nil)])
        #expect(String(decoding: try full.encoded(), as: UTF8.self)
            .contains(#""evaluatedRevision" : null"#))
        #expect(try LintAcceptanceManifest.decode(try full.encoded()) == full)
    }

    // MARK: - The shipped manifest

    @Test func shippedManifestIsStructurallyValid() throws {
        let shipped = try LintAcceptanceManifest.load()
        #expect(shipped.structuralProblem == nil)
    }

    /// Guard: a repair-enabled build MUST ship a manifest whose pipeline
    /// equals this build's live pipeline. Inert while the manifest ships
    /// `defaultReportOnly: true`; it activates on the flip, so a stale
    /// manifest cannot enable repairs.
    @Test func enabledShippedManifestMatchesLiveBuildPipeline() throws {
        let shipped = try LintAcceptanceManifest.load()
        guard shipped.defaultReportOnly == false else { return }
        #expect(shipped.pipeline == (try LintAcceptanceManifest.Pipeline.live()),
                "the shipped LintAcceptance/manifest.json pipeline is stale — re-run the gate and mint a new manifest with `WikiLintEvalRunner manifest`")
    }

    @Test func productionGateSelectsWithoutThrowing() throws {
        let shipped = try LintAcceptanceManifest.load()
        let live = try LintAcceptanceManifest.Pipeline.live()
        let selection = LintAcceptanceGate.production()
            .selection(for: components(pipeline: live))
        if shipped.defaultReportOnly {
            let why = try #require(reason(selection))
            #expect(why.contains("approval pending"))
        }
    }
}
