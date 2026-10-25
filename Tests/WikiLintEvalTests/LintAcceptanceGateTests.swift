import Foundation
import Testing
import WikiFSCore

/// The W5a trust ladder: the rollout gate matches the SHIPPED approval
/// manifest structurally. A matching, evidence-backed row on the live
/// pipeline authorizes repairs; a matched-but-drifted row and ANY
/// unevaluated configuration select staged-proposal (review, not nothing);
/// only a missing/invalid manifest degrades to report-only. Never a throw.
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
        schema: Int = LintAcceptanceManifest.schema
    ) -> LintAcceptanceManifest {
        let rows = approvals ?? [row()]
        return LintAcceptanceManifest(
            manifestSchema: schema,
            pipeline: pipeline, evidence: rows.isEmpty ? nil : evidence,
            approvals: rows)
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
        if case .stagedProposal(let reason) = selection { return reason }
        return nil
    }

    private func stagedReason(_ selection: LintRolloutSelection) -> String? {
        if case .stagedProposal(let reason) = selection { return reason }
        return nil
    }

    // MARK: - Matching (rule 2)

    @Test func matchingRowAuthorizesWithItsID() {
        let gate = LintAcceptanceGate(manifest: manifest())
        #expect(gate.selection(for: components())
            == .repairAuthorized(approvalID: "anthropic-sonnet-low-1"))
    }

    // MARK: - Staged proposals (rules 3 and 4)

    /// Rule 4: ANY unevaluated configuration still lints and stages its
    /// fixes — it is NOT report-only (report-only is degradation only).
    @Test(arguments: [
        ("openai", "claude-sonnet", "low"),
        ("anthropic", "claude-opus", "low"),
        ("anthropic", "claude-sonnet", "high"),
    ])
    func unevaluatedConfigurationSelectsStagedProposal(provider: String, model: String, effort: String) throws {
        let gate = LintAcceptanceGate(manifest: manifest())
        let selection = gate.selection(for: components(
            provider: provider, model: model, effort: effort))
        let why = try #require(stagedReason(selection))
        #expect(why.contains("not yet evaluated"))
    }

    /// An empty-rows manifest (today's shipped shape) stages everything.
    @Test func emptyRowsManifestStagesEveryConfiguration() throws {
        let gate = LintAcceptanceGate(manifest: manifest(approvals: []))
        let selection = gate.selection(for: components(pipeline: try .live()))
        #expect({
            if case .stagedProposal = selection { return true }
            return false
        }())
    }

    /// Rule 3: a row matches but the pipeline drifted — the stale approval
    /// downgrades to review, not to nothing and not to report-only.
    @Test(arguments: ["prompt", "detector", "fixtures"])
    func pipelineDriftDowngradesMatchedRowToStagedProposal(component: String) throws {
        let changed = LintAcceptanceManifest.Pipeline(
            promptSHA256: component == "prompt" ? String(repeating: "d", count: 64) : pipeline.promptSHA256,
            detectorRevision: component == "detector" ? "lint-preflight-v999" : pipeline.detectorRevision,
            fixtureDigest: component == "fixtures" ? String(repeating: "e", count: 64) : pipeline.fixtureDigest)
        let gate = LintAcceptanceGate(manifest: manifest())
        let why = try #require(stagedReason(gate.selection(for: components(pipeline: changed))))
        #expect(why.contains("downgraded to staged review"))
    }

    /// Rule 3: the provider's revision changed since evaluation — staged,
    /// not report-only.
    @Test func revisionMismatchDowngradesToStagedProposal() throws {
        let gate = LintAcceptanceGate(manifest: manifest())
        let why = try #require(stagedReason(gate.selection(for: components(revision: "20260201"))))
        #expect(why.contains("downgraded to staged review"))
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

    /// A pipeline drift on a configuration with NO matching row still stages
    /// (rule 4) — the not-yet-evaluated reason, never a crash.
    @Test func unmatchedRowWithDriftedPipelineIsStagedProposal() throws {
        let changed = LintAcceptanceManifest.Pipeline(
            promptSHA256: String(repeating: "d", count: 64),
            detectorRevision: pipeline.detectorRevision,
            fixtureDigest: pipeline.fixtureDigest)
        let gate = LintAcceptanceGate(manifest: manifest())
        let why = try #require(stagedReason(gate.selection(for: components(
            provider: "deepseek", model: "r1", effort: "low", pipeline: changed))))
        #expect(why.contains("not yet evaluated"))
    }

    // MARK: - Missing / malformed manifests (rule 1 — degradation only)

    @Test(arguments: [
        "not json",
        #"{"manifestSchema":3}"#,
        #"{"manifestSchema":3,"pipeline":{"promptSHA256":"a","detectorRevision":"b","fixtureDigest":"c"},"evidence":null,"approvals":[{"id":"x"}]}"#,
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
            // Unknown schema.
            LintAcceptanceManifest(
                manifestSchema: 2, pipeline: pipeline, evidence: evidence,
                approvals: [row()]),
            // Approvals without evidence.
            LintAcceptanceManifest(
                pipeline: pipeline, evidence: nil, approvals: [row()]),
            // Evidence without approvals.
            LintAcceptanceManifest(
                pipeline: pipeline, evidence: evidence, approvals: []),
            // Unknown authority.
            LintAcceptanceManifest(
                pipeline: pipeline, evidence: evidence,
                approvals: [LintAcceptanceManifest.Approval(
                    id: "x", provider: "anthropic", model: "claude-sonnet", effort: "low",
                    evaluatedRevision: nil, acceptanceKeySHA256: nil, authority: "root")]),
        ]
        for candidate in invalid {
            #expect(candidate.structuralProblem != nil)
            let why = try #require(reason(LintAcceptanceGate(manifest: candidate)
                .selection(for: components())))
            #expect(why.contains("missing or invalid"))
        }
    }

    /// Schema 3 dropped `defaultReportOnly` entirely: the key must not round
    /// trip, and an unknown schema (2, which carried it) is invalid.
    @Test func schemaThreeHasNoDefaultReportOnlySwitch() throws {
        let text = String(decoding: try manifest().encoded(), as: UTF8.self)
        #expect(text.contains("defaultReportOnly") == false,
                "schema 3 removed the defaultReportOnly key")
        // A schema-2 document decodes only by ignoring the removed key, and
        // its schema number is then structurally invalid.
        let legacy = #"{"manifestSchema":2,"pipeline":{"promptSHA256":"a","detectorRevision":"b","fixtureDigest":"c"},"evidence":null,"approvals":[],"defaultReportOnly":true}"#
        let decoded = try LintAcceptanceManifest.decode(Data(legacy.utf8))
        #expect(decoded.structuralProblem != nil)
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
        #expect(shipped.manifestSchema == LintAcceptanceManifest.schema)
        #expect(shipped.structuralProblem == nil)
    }

    /// Guard (W5a): a manifest that ships ANY approval row MUST match this
    /// build's live pipeline — a stale manifest must never authorize
    /// repairs. Inert while rows are empty; it activates on the first
    /// shipped row.
    @Test func shippedApprovalsRequireLiveBuildPipeline() throws {
        let shipped = try LintAcceptanceManifest.load()
        guard shipped.approvals.isEmpty == false else { return }
        #expect(shipped.pipeline == (try LintAcceptanceManifest.Pipeline.live()),
                "the shipped LintAcceptance/manifest.json pipeline is stale — re-run the gate and mint a new manifest with `WikiLintEvalRunner manifest`")
    }

    /// The production gate over today's shipped (row-less) manifest selects
    /// staged-proposal for the live build — never report-only, never a
    /// throw.
    @Test func productionGateSelectsWithoutThrowing() throws {
        let live = try LintAcceptanceManifest.Pipeline.live()
        let selection = LintAcceptanceGate.production()
            .selection(for: components(pipeline: live))
        #expect({
            if case .stagedProposal = selection { return true }
            return false
        }(), "an unevaluated configuration stages proposals; report-only is degradation only")
    }
}
