import Foundation
import WikiFSCore

/// Pure, side-effect-free backend selection + ACP profile wiring (slice 2 of
/// `plans/acp-backend-and-permissions.md`). Extracted from the launcher so the
/// selection logic is unit-testable WITHOUT driving the `@MainActor @Observable`
/// launcher actor (`AgentLauncher` only owns "when + where to construct").
///
/// **Default-OFF contract:** `useACPBackend == false` MUST return
/// `ClaudeCLIBackend` — today's behavior, unchanged for existing users. Only
/// when the opt-in pref is ON does the launcher construct an `ACPBackend`, and
/// even then it is `permissionPolicy: .yolo` by default (default mode = yolo —
/// the safe default, since always-ask enforcement depends on the agent emitting
/// `request_permission`, which not all agents do).
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

    /// Build the `providerHints` that carry the ACP agent spawn (executable path
    /// + args) into the backend's `BackendProfile`. The existing `AgentCommandConfig`
    /// (Settings → Agent) DOUBLES as the ACP agent spawn: its resolved executable
    /// becomes `acpAgentPath` and its prefix-arguments string becomes
    /// `acpAgentArgs`. `ACPBackend.resolveSpawnConfig` tokenizes the args string
    /// with the same shell-aware tokenizer the app uses for `prefixArguments`.
    ///
    /// PURE so it is unit-tested directly (`ACPWiringTests`). Empty inputs yield
    /// an empty dict (→ `ACPBackend` throws `noAgentConfigured`, surfaced to the
    /// user — the opt-in feature requires a configured ACP agent).
    static func acpProviderHints(resolvedExecutable: String, prefixArguments: String) -> [String: String] {
        var hints: [String: String] = [:]
        if !resolvedExecutable.isEmpty {
            hints["acpAgentPath"] = resolvedExecutable
        }
        if !prefixArguments.isEmpty {
            hints["acpAgentArgs"] = prefixArguments
        }
        return hints
    }
}
