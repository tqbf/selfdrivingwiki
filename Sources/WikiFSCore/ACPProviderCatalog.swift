import Foundation

/// Catalog of known ACP-capable agents for filesystem discovery (slice of #217).
///
/// ACP is JSON-RPC over stdio — any installed agent that speaks it is launched as
/// a subprocess the app talks to via `ACPBackend`. This catalog maps each known
/// agent to (a) the PATH binary whose presence means "installed" and (b) the ACP
/// spawn argv.
///
/// **Claude is intentionally NOT here:** the app already drives `claude` directly
/// via `ClaudeCLIBackend` (`claude -p`), the way paseo uses the Claude Agent SDK.
/// ACP is for agents without a native selfdrivingwiki integration (Gemini, Hermes,
/// …). `claude-agent-acp` is therefore not in the catalog.
///
/// Extensible: append entries as agents' ACP invocations are confirmed. Commands
/// verified against paseo's provider docs (`docs/custom-providers.md`).
public struct KnownACPAgent: Sendable, Equatable, Identifiable {
    public let id: String                 // stable provider id, e.g. "gemini"
    public let label: String              // UI label
    public let summary: String
    public let detectExecutable: String   // PATH binary whose presence = "installed"
    public let command: [String]          // ACP spawn argv (command[0] == detectExecutable by convention)

    public init(id: String, label: String, summary: String, detectExecutable: String, command: [String]) {
        self.id = id
        self.label = label
        self.summary = summary
        self.detectExecutable = detectExecutable
        self.command = command
    }
}

public enum ACPProviderCatalog {
    /// Confirmed ACP agents. Add entries here as their ACP invocation is verified.
    public static let agents: [KnownACPAgent] = [
        KnownACPAgent(
            id: "gemini",
            label: "Gemini CLI",
            summary: "Google Gemini CLI over ACP.",
            detectExecutable: "gemini",
            command: ["gemini", "--acp"]),
        KnownACPAgent(
            id: "hermes",
            label: "Hermes",
            summary: "Nous Research Hermes agent over ACP.",
            detectExecutable: "hermes",
            command: ["hermes", "acp"]),
        // Goose, Codex, Qwen Code, Kimi, etc. are ACP-capable too (per the ACP
        // agents list) — add them once each one's exact ACP argv is confirmed, so
        // a discovered provider launches cleanly rather than failing on a guessed
        // command. The discovery mechanism below picks them up automatically.
    ]
}
