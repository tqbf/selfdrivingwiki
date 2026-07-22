#if os(macOS)
import Foundation
import WikiFSCore

/// Pure validation that a provider has an explicitly selected model before the
/// launcher will spawn an ACP subprocess on its behalf.
///
/// Background: without an explicit `selectedModelId`, the launcher passed `nil`
/// to `providerHints`, and the ACP subprocess picked its own first-listed
/// upstream model. For OpenCode that was `opencode/big-pickle` (a free model) —
/// silently, with no UI signal. This guard refuses to spawn instead, setting
/// `AgentLauncher.preflightError` to an actionable message that points the user
/// at Agents settings. See `tmp/ingestion-stall-diagnosis.md` (2026-07-18).
///
/// PURE — no actor, no I/O. Unit-tested directly. Called from two launch sites:
/// - `AgentLauncher.runACPIngestPlannerExecutors` (ingest — validates each of
///   the three per-stage models: planner / executor / finalizer, per
///   `plans/per-stage-model-selection.md` §6)
/// - `AgentLauncher.startInteractiveQuery` (interactive chat)
enum SpawnModelGuard {
    /// Returns `nil` when spawning is allowed (a non-empty `modelId` is set for
    /// `provider`); otherwise a human-readable preflight error message that
    /// names the provider and points the user at Settings → Providers.
    ///
    /// When `stageName` is provided (the per-stage ingest path), the message
    /// names the stage too — e.g. "No model selected for the Planner stage of
    /// provider ‘Claude’." — so a missing *executor*-stage model (with
    /// planner/finalizer set) is diagnosed specifically rather than as a
    /// generic "no model" refusal.
    static func validate(
        provider: AgentProvider,
        modelId: String?,
        stageName: String? = nil
    ) -> String? {
        if let modelId, !modelId.isEmpty { return nil }
        if let stageName, !stageName.isEmpty {
            return "No model selected for the \(stageName) stage of provider ‘\(provider.label)’. "
                 + "Open Settings → Providers and pick a model before running."
        }
        return "No model selected for provider ‘\(provider.label)’. "
             + "Open Settings → Providers and pick a model before running."
    }
}
#endif
