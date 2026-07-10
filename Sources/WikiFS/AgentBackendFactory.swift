import Foundation
import WikiFSCore

/// Pure, side-effect-free backend selection + ACP profile wiring (slice 2 of
/// `plans/acp-backend-and-permissions.md`; provider selection added in #324).
/// Extracted from the launcher so the selection logic is unit-testable WITHOUT
/// driving the `@MainActor @Observable` launcher actor (`AgentLauncher` only
/// owns "when + where to construct").
///
/// Two selection entry points:
/// - `makeBackend(useACPBackend:policy:)` — the slice-3 bool seam (retained so
///   the existing `ACPWiringTests` keep passing). Default-OFF → Claude CLI.
/// - `makeBackend(provider:policy:)` — the #324 provider seam: the launcher
///   picks the provider from `AgentProvidersConfig` and constructs the matching
///   backend. **Default = Claude (`claudeCLI`) → `ClaudeCLIBackend`**, so
///   existing users see zero behavior change.
///
/// The permission policy is baked into the `ACPBackend` at construction
/// (`ACPBackend.start` installs it on the delegate); it has NO effect on the CLI
/// backend (no permission channel).
enum AgentBackendFactory {

    /// Select + construct the backend for a session.
    ///
    /// - Parameters:
    ///   - useACPBackend: the persisted opt-in pref (`@AppStorage("useACPBackend")`,
    ///     default `false`). OFF → Claude CLI (unchanged); ON → ACP.
    ///   - policy: the chat's permission policy (yolo vs alwaysAsk). Baked into
    ///     the `ACPBackend` at construction (`ACPBackend.start` installs it on the
    ///     delegate); ignored by the CLI backend (no permission channel).
    /// - Returns: the backend. `ACPBackend` also conforms to `PermissionResolving`,
    ///   so the launcher downcasts to surface pending requests.
    static func makeBackend(useACPBackend: Bool, policy: PermissionPolicy) -> AgentBackend {
        if useACPBackend {
            return ACPBackend(permissionPolicy: policy)
        }
        return ClaudeCLIBackend()
    }

    /// Select + construct the backend from a provider (#324). `provider.backend`
    /// picks the backend kind; the permission policy applies only to `.acp`
    /// providers (the CLI backend has no permission channel). **Default = Claude
    /// (`claudeCLI`) → `ClaudeCLIBackend`**, so existing users see no change.
    /// PURE so the selection→backend mapping is unit-tested directly
    /// (`ACPProviderSelectionTests`).
    static func makeBackend(provider: AgentProvider, policy: PermissionPolicy) -> AgentBackend {
        switch provider.backend {
        case .claudeCLI:
            return ClaudeCLIBackend()
        case .acp:
            return ACPBackend(permissionPolicy: policy)
        }
    }

    /// Build the `providerHints` for an ACP provider from its PATH-resolved
    /// command + the Keychain-backed API key (#324). Mirrors the slice-3
    /// `acpProviderHints(resolvedExecutable:prefixArguments:apiKey:)` contract:
    /// `acpAgentPath` is the resolved executable, `acpAgentArgs` is the rest of
    /// the argv (joined so `ACPBackend.resolveSpawnConfig` can tokenize it), and
    /// `acpAgentApiKey` carries the secret. PURE.
    ///
    /// #329: `acpSelectedModelId` carries the user's per-provider model pick so
    /// `ACPBackend.start` can call `session/set_model` after `newSession`. nil
    /// /empty = "use the agent's default model" (no `setModel`) → unchanged.
    ///
    /// A `.claudeCLI` provider yields an empty dict (the CLI backend ignores
    /// providerHints — it reads `CLIProfile`). An ACP provider with an empty
    /// command yields an empty dict too (→ `ACPBackend` throws
    /// `noAgentConfigured`).
    static func providerHints(
        provider: AgentProvider,
        resolvedCommand: [String],
        apiKey: String?,
        selectedModelId: String? = nil
    ) -> [String: String] {
        guard provider.backend == .acp, !resolvedCommand.isEmpty else { return [:] }
        var hints: [String: String] = [:]
        hints["acpAgentPath"] = resolvedCommand[0]
        let args = resolvedCommand.dropFirst()
        if !args.isEmpty {
            hints["acpAgentArgs"] = args.joined(separator: " ")
        }
        if let apiKey, !apiKey.isEmpty {
            hints["acpAgentApiKey"] = apiKey
        }
        if let selectedModelId, !selectedModelId.isEmpty {
            hints["acpSelectedModelId"] = selectedModelId
        }
        return hints
    }

    /// Build the `providerHints` that carry the ACP agent spawn (executable path
    /// + args + auth key) into the backend's `BackendProfile`.
    ///
    /// Slice 3: sourced from the DEDICATED `ACPAgentConfig` (Settings → Agent →
    /// ACP Agent) — NOT the generic `AgentCommandConfig`. The resolved executable
    /// becomes `acpAgentPath`, the prefix-arguments string becomes
    /// `acpAgentArgs`, and the Keychain-backed API key becomes
    /// `acpAgentApiKey`. `ACPBackend.resolveSpawnConfig` tokenizes the args
    /// string with the same shell-aware tokenizer the app uses for
    /// `prefixArguments`.
    ///
    /// PURE so it is unit-tested directly (`ACPConfigTests` / `ACPWiringTests`).
    /// Empty executable yields an empty dict (→ `ACPBackend` throws
    /// `noAgentConfigured`, surfaced to the user — the opt-in feature requires a
    /// configured ACP agent).
    static func acpProviderHints(
        resolvedExecutable: String,
        prefixArguments: String,
        apiKey: String?
    ) -> [String: String] {
        var hints: [String: String] = [:]
        if !resolvedExecutable.isEmpty {
            hints["acpAgentPath"] = resolvedExecutable
        }
        if !prefixArguments.isEmpty {
            hints["acpAgentArgs"] = prefixArguments
        }
        if let apiKey, !apiKey.isEmpty {
            hints["acpAgentApiKey"] = apiKey
        }
        return hints
    }
}
