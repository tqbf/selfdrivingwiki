import Foundation

/// Dedicated configuration for the ACP (Agent Client Protocol) agent spawn —
/// the SEPARATE config slice 3 introduces so the ACP backend is configured
/// independently from the Claude-CLI `AgentCommandConfig`.
///
/// Mirrors `AgentCommandConfig`'s fields (executable, prefix arguments, model
/// override, extra environment) + persistence pattern (atomic JSON in the App
/// Group container, loaded fresh at spawn time). The one thing it deliberately
/// does NOT carry is the auth **API key** — that goes through the Keychain-backed
/// `ACPCredentialStore`, never in a plaintext JSON file. This mirrors
/// `ExtractionConfig` (plain prefs) + `ExtractionCredentialStore` (secrets).
///
/// App-wide, not per-wiki: a property of the user's environment, like
/// `AgentCommandConfig` and `ZoteroConfig`. Follows the same `Codable` +
/// atomic-JSON-in-App-Group-container pattern.
public struct ACPAgentConfig: Codable, Equatable, Sendable {

    /// Binary or wrapper script that launches the ACP agent (default `npx`).
    /// Resolved on the login-shell PATH, or used directly if absolute / `./` /
    /// `../`; `~` is expanded — same resolution rules as `AgentCommandConfig`.
    public var executable: String

    /// Args inserted before nothing (the ACP agent owns its own argv after the
    /// executable). Covers `--yes @agentclientprotocol/claude-agent-acp` without
    /// a wrapper script. Stored as a single string (shell-tokenized at use time);
    /// non-nil so Codable round-trips cleanly.
    public var prefixArguments: String

    /// Model override, e.g. `"claude-sonnet-4-5"`. Blank means let the agent pick.
    public var modelOverride: String

    /// Extra environment variables as `KEY=VALUE` lines. Merged into the spawned
    /// process environment; app-owned keys always win.
    public var extraEnvironment: String

    public init(
        executable: String = "npx",
        prefixArguments: String = "--yes @agentclientprotocol/claude-agent-acp",
        modelOverride: String = "",
        extraEnvironment: String = ""
    ) {
        self.executable = executable
        self.prefixArguments = prefixArguments
        self.modelOverride = modelOverride
        self.extraEnvironment = extraEnvironment
    }

    /// A sensible default that launches the canonical Claude ACP agent via npx.
    /// Used when no `acp-agent-config.json` exists yet.
    public static let `default` = ACPAgentConfig()

    /// The config's JSON filename inside the App Group container. Distinct from
    /// `AgentCommandConfig.fileName` so the two backends persist independently.
    public static let fileName = "acp-agent-config.json"

    // MARK: - Persistence

    /// Load from `acp-agent-config.json` in `directory`. Missing or corrupt file
    /// degrades to `.default` rather than throwing — same fresh-install behavior
    /// as `AgentCommandConfig.load` / `ZoteroConfig.load`.
    public static func load(from directory: URL) -> ACPAgentConfig {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return .default }
        guard let config = try? JSONDecoder().decode(ACPAgentConfig.self, from: data) else {
            DebugLog.config("ACPAgentConfig: corrupt \(fileName), starting default")
            return .default
        }
        return config
    }

    /// Persist to `acp-agent-config.json` in `directory`, atomically,
    /// pretty-printed + sorted keys. Never writes the API key (that is the
    /// `ACPCredentialStore`'s job).
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(ACPAgentConfig.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Derived values

    /// Resolve the executable: expand `~`, return directly if absolute or
    /// `./`/`../`, otherwise leave as-is for PATH resolution. Mirrors
    /// `AgentCommandConfig.resolvedExecutable`.
    public func resolvedExecutable() -> String {
        AgentCommandConfig.expandTilde(executable.isEmpty ? "npx" : executable)
    }

    /// Tokenize `prefixArguments` into an argv array. Empty string → `[]`.
    /// Reuses the shared shell-aware tokenizer so quoting matches the rest of the app.
    public func tokenizedPrefixArgs() -> [String] {
        AgentCommandConfig.tokenize(prefixArguments).filter { !$0.isEmpty }
    }

    /// Parse `extraEnvironment` into a `[String: String]` dictionary. Delegates to
    /// `AgentCommandConfig`'s parser (bash-style assignment lines, `$VAR`/`${VAR}`
    /// expansion, single-quote literal handling) so behavior is identical.
    public func parsedExtraEnv() -> [String: String] {
        // Reuse the shared parser by constructing an ephemeral AgentCommandConfig
        // whose only non-default field is `extraEnvironment`. The parser is a pure
        // function of that one field, so this is exact and allocation-cheap.
        AgentCommandConfig(
            executable: "claude",
            prefixArguments: "",
            modelOverride: "",
            extraEnvironment: extraEnvironment
        ).parsedExtraEnv()
    }
}
