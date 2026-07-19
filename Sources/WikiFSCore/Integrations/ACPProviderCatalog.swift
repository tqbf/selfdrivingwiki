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
/// **Claude via ACP:** the `claude-acp` entry runs `@agentclientprotocol/claude-agent-acp`
/// via `bunx` — the official ACP wrapper around Claude Code. This is the default
/// chat path; the legacy `claude -p` CLI provider is retained but disabled.
/// Other entries (Gemini, Hermes, …) are agents without a native integration.
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
    /// Pre-#665 hardcoded catalog — the confirmed ACP agents ported from
    /// paseo's `acp-provider-catalog.ts`. Each entry's `command[0]` is its
    /// `detectExecutable`.
    ///
    /// Kept as the **last-resort** fallback when the live registry, the
    /// cache, AND the bundled snapshot are all unavailable (offline first run,
    /// corrupt bundle, etc.). The runtime catalog is loaded from the official
    /// ACP registry via `loadAgents()` (`agents` serves the bundled snapshot
    /// synchronously for non-async contexts).
    public static let fallbackCatalog: [KnownACPAgent] = [
        KnownACPAgent(
            id: "claude-acp",
            label: "Claude",
            summary: "Claude Code via the official ACP wrapper (bunx @agentclientprotocol/claude-agent-acp).",
            detectExecutable: "bun",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"]),
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
        KnownACPAgent(
            id: "opencode",
            label: "OpenCode",
            summary: "Open-source terminal AI coding agent with multi-provider support.",
            detectExecutable: "opencode",
            command: ["opencode", "acp"]),
    ]

    /// Sync accessor for contexts that can't `await` (SwiftUI previews,
    /// deterministic test fixtures, the Add Provider sheet's first paint).
    ///
    /// Order: bundled snapshot → `fallbackCatalog`. The bundled snapshot is
    /// the official registry JSON shipped in `Contents/Resources/acp-registry.json`;
    /// if the bundle lookup fails (e.g. running under `swift test`, where
    /// `Bundle.main` is the test runner — not the .app), this degrades to the
    /// hardcoded `fallbackCatalog`.
    ///
    /// For the live (cached + networked) registry, use `loadAgents()` (async).
    public static var agents: [KnownACPAgent] {
        guard let url = ACPRegistryClient.bundledURL else { return fallbackCatalog }
        // Read + decode, routing failures through DebugLog (house rule: never
        // bare `try?`). A missing/corrupt bundled snapshot is rare-but-fixable
        // signal: log it so Console.app shows the regression on launch.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            DebugLog.agent("ACPProviderCatalog.agents: bundled snapshot read failed — \(error.localizedDescription)")
            return fallbackCatalog
        }
        let response: ACPRegistryResponse
        do {
            response = try JSONDecoder().decode(ACPRegistryResponse.self, from: data)
        } catch {
            DebugLog.agent("ACPProviderCatalog.agents: bundled snapshot decode failed — \(error.localizedDescription)")
            return fallbackCatalog
        }
        let mapped = ACPRegistryClient.mapRegistryToCatalog(response)
        // Empty decoded payload → fall through to the hardcoded list (don't
        // silently render an empty catalog).
        return mapped.isEmpty ? fallbackCatalog : mapped
    }

    /// Async accessor: the live registry with cache + offline fallback. Always
    /// returns SOME list (worst case, `fallbackCatalog`). Never throws —
    /// network errors are logged via `DebugLog.agent` and the call degrades.
    public static func loadAgents() async -> [KnownACPAgent] {
        await ACPRegistryClient.loadAgents()
    }
}
