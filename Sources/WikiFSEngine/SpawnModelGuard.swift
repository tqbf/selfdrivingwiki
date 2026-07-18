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
/// - `AgentLauncher.resolveStageRouting` (ingest — covers planner/executor/
///   finalizer through one choke-point)
/// - `AgentLauncher.startInteractiveQuery` (interactive chat)
enum SpawnModelGuard {
    /// Returns `nil` when spawning is allowed (a non-empty `modelId` is set for
    /// `provider`); otherwise a human-readable preflight error message that
    /// names the provider and points the user at Settings → Agents.
    static func validate(provider: AgentProvider, modelId: String?) -> String? {
        if let modelId, !modelId.isEmpty { return nil }
        return "No model selected for provider ‘\(provider.label)’. "
             + "Open Settings → Agents and pick a model before running."
    }
}
