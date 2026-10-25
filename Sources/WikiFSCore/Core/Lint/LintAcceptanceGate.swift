import Foundation
import WikiFSTypes

/// The acceptance key (plan §6.13/§6.14): the digest of every component an
/// evaluation was run against. The eval harness names its evidence with it,
/// and a shipped approval row may carry it for traceability. The rollout
/// gate itself matches the shipped manifest structurally — see
/// `LintAcceptanceGate`.
public struct LintAcceptanceKey: Equatable, Sendable, Hashable {

    /// Every component that changes the key: provider, model, the provider's
    /// advertised revision fingerprint when available, the effective effort
    /// tier, the prompt bytes hash, the detector revision, and the shipped
    /// gate-fixture digests (plan §6.12 — a changed component invalidates
    /// all prior evidence).
    public struct Components: Equatable, Sendable {
        public let provider: String
        public let model: String
        public let modelRevision: String?
        public let effort: String
        public let promptSHA256: String
        public let detectorRevision: String
        public let fixtureDigest: String

        public init(
            provider: String, model: String, modelRevision: String?,
            effort: String, promptSHA256: String, detectorRevision: String,
            fixtureDigest: String
        ) {
            self.provider = provider
            self.model = model
            self.modelRevision = modelRevision
            self.effort = effort
            self.promptSHA256 = promptSHA256
            self.detectorRevision = detectorRevision
            self.fixtureDigest = fixtureDigest
        }

        /// The stable canonical string the digest hashes (sorted labels).
        public var canonical: String {
            let parts: [(String, String)] = [
                ("provider", provider),
                ("model", model),
                ("revision", modelRevision ?? "unavailable"),
                ("effort", effort),
                ("prompt", promptSHA256),
                ("detector", detectorRevision),
                ("fixtures", fixtureDigest),
            ]
            return parts.sorted { $0.0 < $1.0 }
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: "\n")
        }
    }

    /// The SHA-256 hex of the canonical components — the evidence name and
    /// an approval row's `acceptanceKeySHA256`.
    public static func digest(_ components: Components) -> String {
        RendererSHA256.digest(Data(components.canonical.utf8)).hex
    }
}

/// What the trusted coordinator selects for a configuration. The trust
/// ladder (W5a): an evaluated configuration repairs directly, ANY
/// unevaluated configuration still lints and fixes but stages its hunks for
/// human review, and report-only is reserved for degradation.
public enum LintRolloutSelection: Equatable, Sendable {
    /// A shipped approval row matches — the repair-capable lease. The id
    /// names the row that authorized it.
    case repairAuthorized(approvalID: String)
    /// An unevaluated (or drifted) configuration: the run still lints and
    /// FIXES, but its hunks are staged for human review — never written
    /// directly. A stale approval downgrades to this tier, not to nothing.
    case stagedProposal(reason: String)
    /// An ERROR/degradation outcome: report-only instructions and
    /// authority, with the reason recorded in artifacts and queue/UI state.
    case reportOnly(reason: String)
}

/// The gate itself: structural matching against the SHIPPED approval
/// manifest (`LintAcceptanceManifest`). There is no per-machine record and
/// no write path — the approval ships inside the app, keyed to the
/// pipeline. Every outcome is a selection; nothing here throws.
public struct LintAcceptanceGate: Sendable {

    enum Source: Sendable {
        case manifest(LintAcceptanceManifest)
        case unavailable(reason: String)
    }

    let source: Source

    /// A gate over an already-decoded manifest (tests, tooling).
    public init(manifest: LintAcceptanceManifest) {
        self.source = .manifest(manifest)
    }

    /// A gate over raw manifest bytes. Bytes that do not decode select
    /// report-only at gate time.
    public init(manifestData: Data) {
        do {
            self.source = .manifest(try LintAcceptanceManifest.decode(manifestData))
        } catch {
            self.source = .unavailable(reason: "manifest does not decode: \(error)")
        }
    }

    /// A gate whose manifest could not be read at all.
    public init(unavailableReason reason: String) {
        self.source = .unavailable(reason: reason)
    }

    /// The production gate: the manifest shipped in the WikiFSCore bundle.
    /// A missing or unreadable resource yields a gate that selects
    /// report-only — never a crash.
    public static func production() -> LintAcceptanceGate {
        do {
            return LintAcceptanceGate(manifestData: try LintAcceptanceManifest.shippedData())
        } catch {
            return LintAcceptanceGate(unavailableReason: "shipped manifest unavailable: \(error)")
        }
    }

    /// The rollout selection for one configuration. Checks run in order;
    /// the first matching rule wins:
    ///
    /// 1. manifest missing/unreadable/undecodable/structurally invalid →
    ///    `.reportOnly` (degradation);
    /// 2. a row matches (provider/model/effort) AND the pipeline is equal
    ///    AND the revision rule passes → `.repairAuthorized`;
    /// 3. a row matches but the pipeline drifted or the revision changed →
    ///    `.stagedProposal` (a stale approval downgrades to review);
    /// 4. no matching row → `.stagedProposal` (any unevaluated
    ///    configuration still lints and stages fixes for review).
    public func selection(for components: LintAcceptanceKey.Components) -> LintRolloutSelection {
        let manifest: LintAcceptanceManifest
        switch source {
        case .unavailable(let reason):
            return .reportOnly(
                reason: "the shipped lint approval manifest is missing or invalid (\(reason)) — run repairs stay staged for review")
        case .manifest(let loaded):
            manifest = loaded
        }
        if let problem = manifest.structuralProblem {
            return .reportOnly(
                reason: "the shipped lint approval manifest is missing or invalid (\(problem)) — run repairs stay staged for review")
        }
        let pipelineMatches = LintAcceptanceManifest.Pipeline(components) == manifest.pipeline
        guard let row = manifest.approvals.first(where: {
            $0.provider == components.provider
                && $0.model == components.model
                && $0.effort == components.effort
        }) else {
            return .stagedProposal(
                reason: "configuration not yet evaluated — repairs staged for your review")
        }
        if pipelineMatches == false {
            return .stagedProposal(
                reason: "the lint pipeline changed since this configuration was evaluated — its approval downgraded to staged review until a fresh gate")
        }
        // Documented limitation: a revision missing on EITHER side does not
        // fail the match — only two known, different revisions do.
        if let evaluated = row.evaluatedRevision,
           let current = components.modelRevision,
           evaluated != current {
            return .stagedProposal(
                reason: "the provider's model revision changed since evaluation — its approval downgraded to staged review until re-evaluation")
        }
        return .repairAuthorized(approvalID: row.id)
    }

    /// The evaluation admission (plan §6.13): a harness-only restricted
    /// admission for the disposable wiki ids the harness JUST created, for
    /// the exact evaluated configuration. It can never authorize an operator
    /// wiki.
    public static func evaluationAdmission(
        admittedWikiIDs: Set<WikiID>, requestedWikiID: WikiID
    ) -> Bool {
        admittedWikiIDs.contains(requestedWikiID)
    }
}
