import Foundation
import WikiFSCore
import WikiLintEval

/// The trusted coordinator's rollout gate (plan §6.13): BEFORE requesting a
/// repair-capable lease, compute this configuration's acceptance key from
/// the live components (provider, model, advertised revision, effective
/// effort, the lint-task prompt bytes hash, the detector revision, and the
/// SHIPPED gate-fixture digests) and read the matching record. Missing,
/// invalid, stale, or unmatched evidence selects report-only — with the
/// reason recorded in artifacts and queue/UI state.
public enum LintCoordinatorGate {

    /// The live gate components for the lint coordinator's configuration.
    /// `promptSHA256` hashes the lint-page-task TEMPLATE bytes (not the
    /// per-page rendering), so a prompt change invalidates evidence.
    public static func components(
        provider: String, model: String, modelRevision: String?, effort: String
    ) throws -> LintAcceptanceKey.Components {
        LintAcceptanceKey.Components(
            provider: provider,
            model: model,
            modelRevision: modelRevision,
            effort: effort,
            promptSHA256: promptHash(),
            detectorRevision: LintPreflightReport.detectorRevision,
            fixtureDigest: try shippedFixtureDigest())
    }

    /// The SHA-256 hex of the synced lint-page-task resource bytes.
    public static func promptHash() -> String {
        LintPromptBodies.lintPageTaskSHA256
    }

    /// The frozen fixture digest from the shipped gate manifest — the
    /// canonical gate set. A fixture update changes this value.
    public static func shippedFixtureDigest() throws -> String {
        guard let digest = try LintGateFixtureManifestShipped.load()
            .digest(named: "canonical-gate") else {
            throw LintCoordinatorGateError.missingShippedDigest
        }
        return digest
    }

    /// Consult the production gate. Never throws for "no record" — that is
    /// a report-only selection, not an error. Review M8: an UNKNOWN
    /// component (a provider/model/effort that was never resolved through
    /// the live configuration path) hard-fails to report-only BEFORE any
    /// record lookup — a constant key would be publicly computable, and one
    /// same-user file at that key must never authorize repairs for every
    /// provider and model.
    public static func selection(
        provider: String, model: String, modelRevision: String?, effort: String
    ) throws -> LintRolloutSelection {
        let unknownComponents = [provider, model, effort]
            .filter { $0.isEmpty || $0 == "unconfigured" }
        if unknownComponents.isEmpty == false || modelRevision == nil {
            return .reportOnly(
                reason: "gate components not fully resolved (provider/model/revision/effort) — a configuration must be wired through the live path before repairs can be authorized")
        }
        return try LintAcceptanceGate.production()
            .selection(for: components(
                provider: provider, model: model,
                modelRevision: modelRevision, effort: effort))
    }
}

public enum LintCoordinatorGateError: Error, Equatable {
    case missingShippedDigest
}
