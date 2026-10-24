import Foundation
import WikiFSCore

/// The trusted coordinator's rollout gate (plan §6.13): BEFORE requesting a
/// repair-capable lease, assemble this configuration's live components
/// (provider, model, advertised revision, effective effort, and this
/// build's pipeline — the lint-task prompt bytes hash, the detector
/// revision, and the SHIPPED gate-fixture digest) and match them against
/// the shipped approval manifest. A missing approval, a changed pipeline,
/// or an unmatched configuration selects report-only — with the reason
/// recorded in artifacts and queue/UI state.
public enum LintCoordinatorGate {

    /// The live gate components for the lint coordinator's configuration.
    /// The pipeline comes from `LintAcceptanceManifest.Pipeline.live()`; its
    /// prompt hash covers the lint-page-task TEMPLATE bytes (not the
    /// per-page rendering), so a prompt change invalidates the approval.
    public static func components(
        provider: String, model: String, modelRevision: String?, effort: String
    ) throws -> LintAcceptanceKey.Components {
        let pipeline = try LintAcceptanceManifest.Pipeline.live()
        return LintAcceptanceKey.Components(
            provider: provider,
            model: model,
            modelRevision: modelRevision,
            effort: effort,
            promptSHA256: pipeline.promptSHA256,
            detectorRevision: pipeline.detectorRevision,
            fixtureDigest: pipeline.fixtureDigest)
    }

    /// Consult the production gate. Never throws for "not approved" — that
    /// is a report-only selection, not an error; it throws only when this
    /// build's own pipeline cannot be computed. Review M8: an UNKNOWN
    /// component (a provider/model/effort that was never resolved through
    /// the live configuration path) hard-fails to report-only BEFORE any
    /// manifest consultation — a placeholder configuration must never be
    /// matched against the approved matrix.
    public static func selection(
        provider: String, model: String, modelRevision: String?, effort: String
    ) throws -> LintRolloutSelection {
        let unknownComponents = [provider, model, effort]
            .filter { $0.isEmpty || $0 == "unconfigured" }
        if unknownComponents.isEmpty == false || modelRevision == nil {
            return .reportOnly(
                reason: "gate components not fully resolved (provider/model/revision/effort) — a configuration must be wired through the live path before repairs can be authorized")
        }
        return LintAcceptanceGate.production()
            .selection(for: try components(
                provider: provider, model: model,
                modelRevision: modelRevision, effort: effort))
    }
}
