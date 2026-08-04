#if os(macOS)
import Foundation
import WikiFSCore

/// Pure model-selection validation at the ACP launch seam.
///
/// A nil selection is deliberate: it inherits the provider's agent default,
/// so ACP starts without `session/set_model`. An explicit non-empty model still
/// pins that model for the run.
///
/// PURE — no actor, no I/O. Unit-tested directly. Called from two launch sites:
/// - `AgentLauncher.runACPIngestPlannerExecutors` (ingest — validates each of
///   the three per-stage models: planner / executor / finalizer, per
///   `plans/per-stage-model-selection.md` §6)
/// - `AgentLauncher.startInteractiveQuery` (interactive chat)
enum SpawnModelGuard {
    /// A stage may either pin a model or inherit the provider's agent default;
    /// both are valid ACP launch configurations. Provider availability is
    /// validated independently before this seam.
    static func validate(
        provider: AgentProvider,
        modelId: String?,
        stageName: String? = nil
    ) -> String? {
        _ = provider
        _ = modelId
        _ = stageName
        return nil
    }
}
#endif
