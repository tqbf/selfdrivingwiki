/// Compile-time-checked keys for `BackendProfile.providerHints` — the dict
/// that threads ACP spawn config from `AgentBackendFactory` to
/// `ACPBackend.resolveSpawnConfig`. Using the enum's `rawValue` instead of a
/// bare string literal prevents typos that silently route to `nil`.
public enum HintKey: String, Sendable {
    /// The resolved ACP agent executable path.
    case acpAgentPath
    /// Extra argv for the ACP agent (joined; tokenized by the reader).
    case acpAgentArgs
    /// The Keychain-backed API key for the ACP agent.
    case acpAgentApiKey
    /// The user's per-provider model selection (threads into `session/set_model`).
    case acpSelectedModelId
    /// #727: the provider id this backend was spawned for (so the send catch
    /// block can pass it to `ProviderQuotaDetector` for family disambiguation
    /// and the launcher can tag the dead-provider map). Threaded by
    /// `AgentBackendFactory.providerHints`.
    case acpProviderId

    /// Prefix for environment-variable hints expanded into the child process
    /// environment by `ACPBackend.resolveSpawnConfig`.
    public static let envPrefix = "env."

    /// Build an environment hint key, e.g. `HintKey.env("WIKI_WORKSPACE")`
    /// → `"env.WIKI_WORKSPACE"`.
    public static func env(_ key: String) -> String {
        envPrefix + key
    }

    /// Strip the `env.` prefix from a hint key, returning the environment
    /// variable name. Returns `nil` if the key does not have the prefix.
    public static func envKey(from hintKey: String) -> String? {
        guard hintKey.hasPrefix(envPrefix) else { return nil }
        return String(hintKey.dropFirst(envPrefix.count))
    }
}
