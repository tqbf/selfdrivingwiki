import Foundation

/// Catalog of known ACP-capable agents for filesystem discovery (slice of #217,
/// expanded in #324 to mirror paseo's `acp-provider-catalog.ts`).
///
/// ACP is JSON-RPC over stdio — any installed agent that speaks it is launched as
/// a subprocess the app talks to via `ACPBackend`. This catalog maps each known
/// agent to (a) the PATH binary whose presence means "installed" and (b) the ACP
/// spawn argv. It backs BOTH discovery (`ACPProviderDiscovery`) and the Add
/// Provider catalog in Settings.
///
/// **Claude is intentionally NOT here:** the app already drives `claude` directly
/// via `ClaudeCLIBackend` (`claude -p`), the way paseo uses the Claude Agent SDK.
/// ACP is for agents without a native selfdrivingwiki integration (Gemini, Hermes,
/// …). `claude-agent-acp` is therefore not in the catalog.
///
/// Extensible: append entries as agents' ACP invocations are confirmed. Commands
/// verified against paseo's `acp-provider-catalog.ts`. Convention: `command[0]`
/// equals `detectExecutable` (pinned by `ACPProviderDiscoveryTests`).
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
    /// Confirmed ACP agents, ported from paseo's `acp-provider-catalog.ts`.
    /// Each entry's `command[0]` is its `detectExecutable`. Add entries here as
    /// their ACP invocation is verified.
    public static let agents: [KnownACPAgent] = [
        KnownACPAgent(
            id: "gemini",
            label: "Gemini CLI",
            summary: "Google's official CLI for Gemini over ACP.",
            detectExecutable: "gemini",
            command: ["gemini", "--acp"]),
        KnownACPAgent(
            id: "hermes",
            label: "Hermes",
            summary: "Nous Research self-improving AI agent over ACP.",
            detectExecutable: "hermes",
            command: ["hermes", "acp"]),
        KnownACPAgent(
            id: "copilot",
            label: "GitHub Copilot",
            summary: "GitHub Copilot's coding agent over ACP.",
            detectExecutable: "copilot",
            command: ["copilot", "--acp"]),
        KnownACPAgent(
            id: "kimi",
            label: "Kimi Code CLI",
            summary: "Moonshot AI's open-source terminal coding agent over ACP.",
            detectExecutable: "kimi",
            command: ["kimi", "acp"]),
        KnownACPAgent(
            id: "cursor",
            label: "Cursor",
            summary: "Cursor's coding agent over ACP.",
            detectExecutable: "cursor-agent",
            command: ["cursor-agent", "acp"]),
        KnownACPAgent(
            id: "kiro",
            label: "Kiro CLI",
            summary: "Amazon's AI coding agent with native ACP support.",
            detectExecutable: "kiro-cli",
            command: ["kiro-cli", "acp"]),
        KnownACPAgent(
            id: "goose",
            label: "Goose",
            summary: "A local, extensible, open source AI agent from Block.",
            detectExecutable: "goose",
            command: ["goose", "acp"]),
        KnownACPAgent(
            id: "grok",
            label: "Grok",
            summary: "xAI's Grok Build agentic coding CLI over ACP.",
            detectExecutable: "grok",
            command: ["grok", "agent", "stdio"]),
        KnownACPAgent(
            id: "codewhale",
            label: "CodeWhale",
            summary: "Terminal coding agent for DeepSeek V4 and open models.",
            detectExecutable: "codewhale",
            command: ["codewhale", "serve", "--acp"]),
        KnownACPAgent(
            id: "kilo",
            label: "Kilo",
            summary: "The open source coding agent over ACP.",
            detectExecutable: "kilo",
            command: ["kilo", "acp"]),
        // npx-backed wrappers: `detectExecutable` is `npx` (the binary on PATH),
        // while `command` runs the published ACP package. The launcher
        // PATH-resolves `npx` and passes the rest as argv.
        KnownACPAgent(
            id: "claude-agent-acp",
            label: "Claude (ACP)",
            summary: "Claude over the ACP adapter (npx wrapper).",
            detectExecutable: "npx",
            command: ["npx", "--yes", "@agentclientprotocol/claude-agent-acp"]),
        KnownACPAgent(
            id: "codex-acp",
            label: "Codex (ACP)",
            summary: "OpenAI Codex over the ACP adapter (npx wrapper).",
            detectExecutable: "npx",
            command: ["npx", "--yes", "@zed-industries/codex-acp"]),
    ]
}
