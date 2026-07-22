import Foundation
import WikiFSCore

/// Pure, side-effect-free ACP profile wiring (slice 2 of
/// `plans/acp-backend-and-permissions.md`; provider selection added in #324;
/// the legacy CLI backend was removed in Phase 4 of
/// `plans/acp-multi-provider.md` — the app is ACP-only now).
/// Extracted from the launcher so the selection logic is unit-testable WITHOUT
/// driving the `@MainActor @Observable` launcher actor (`AgentLauncher` only
/// owns "when + where to construct").
///
/// The permission policy is baked into the `ACPBackend` at construction
/// (`ACPBackend.start` installs it on the delegate).
public enum AgentBackendFactory {

    /// Construct the backend for a session. Every provider drives `ACPBackend`.
    ///
    /// - Parameters:
    ///   - budget: #606 auto-reject budget for deferred permission
    ///     requests. nil (default) = no timer (interactive chat — current
    ///     behavior); non-nil = a stuck permission auto-rejects after this
    ///     `Duration` so unattended pipelines (ingest/lint) can't stall for the
    ///     full 1800s ceiling.
    ///   - turnCeilingTimeout: #609 hard ceiling on total turn duration. The
    ///     caller picks this per context via `TurnLivenessPolicy.ceiling(for:)`:
    ///     `.chat` (interactive) → `defaultCeilingTimeout` (1800s);
    ///     `.ingest`/`.lint` (queued) → `queuedIngestCeiling` (600s). Defaults
    ///     to the interactive value for callers that don't differentiate
    ///     (matching the underlying `ACPBackend.init` default).
    static func makeBackend(
        policy: PermissionPolicy,
        budget: Duration? = nil,
        turnCeilingTimeout: TimeInterval = TurnLivenessPolicy.defaultCeilingTimeout
    ) -> AgentBackend {
        #if os(macOS)
        ACPBackend(
            permissionPolicy: policy,
            budget: budget,
            turnCeilingTimeout: turnCeilingTimeout)
        #else
        // Linux: ACPBackend is unavailable (the `ACP` product is macOS-only).
        // This factory method is only called from macOS code paths (the app
        // and its tests). On Linux the queue tests use mock backends.
        fatalError("AgentBackendFactory.makeBackend requires the ACP product (macOS-only)")
        #endif
    }

    /// Build the `providerHints` for an ACP provider from its PATH-resolved
    /// command + the Keychain-backed API key (#324). `acpAgentPath` is the
    /// resolved executable, `acpAgentArgs` is the rest of the argv (joined so
    /// `ACPBackend.resolveSpawnConfig` can tokenize it), and `acpAgentApiKey`
    /// carries the secret. PURE.
    ///
    /// #329: `acpSelectedModelId` carries the user's per-provider model pick so
    /// `ACPBackend.start` can call `session/set_model` after `newSession`. nil
    /// /empty = "use the agent's default model" (no `setModel`) → unchanged.
    ///
    /// An ACP provider with an empty resolved command yields an empty dict (→
    /// `ACPBackend` throws `noAgentConfigured`).
    static func providerHints(
        provider: AgentProvider,
        resolvedCommand: [String],
        apiKey: String?,
        selectedModelId: String? = nil
    ) -> [String: String] {
        guard !resolvedCommand.isEmpty else { return [:] }
        var hints: [String: String] = [:]
        hints[HintKey.acpAgentPath.rawValue] = resolvedCommand[0]
        let args = resolvedCommand.dropFirst()
        if !args.isEmpty {
            hints[HintKey.acpAgentArgs.rawValue] = args.joined(separator: " ")
        }
        if let apiKey, !apiKey.isEmpty {
            hints[HintKey.acpAgentApiKey.rawValue] = apiKey
        }
        if let selectedModelId, !selectedModelId.isEmpty {
            hints[HintKey.acpSelectedModelId.rawValue] = selectedModelId
        }
        hints[HintKey.acpProviderId.rawValue] = provider.id
        // Phase 2 (plans/acp-multi-provider.md): thread the provider's extra
        // environment into the spawn via the established `env.`-prefix
        // convention (`ACPBackend.start` expands `env.*` hints into the child
        // process environment, e.g. the Phase-7 `WIKI_WORKSPACE` injection).
        // Non-secret knobs only — API keys stay in `acpAgentApiKey`/the Keychain.
        for (key, value) in provider.env {
            hints[HintKey.env(key)] = value
        }
        return hints
    }
}
