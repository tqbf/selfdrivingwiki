import Foundation

/// Which agent backend a provider drives (slice of #324 — provider model).
///
/// `.claudeCLI` = the existing `ClaudeCLIBackend` (drives `claude -p` directly;
/// no spawn argv — the CLI backend owns the `OperationCommand`). `.acp` = the
/// existing `ACPBackend`, which spawns the agent subprocess over JSON-RPC/stdio
/// using the provider's `command` argv. The two backends are already in `main`;
/// this enum is the per-provider switch the launcher reads at spawn time.
public enum AgentBackendKind: String, Codable, Sendable, CaseIterable {
    case claudeCLI
    case acp
}

/// A configured agent provider — the persisted unit the provider Settings UI and
/// the launcher work with (slice of #324 — provider model, modeled on paseo's
/// `providers-section.tsx`).
///
/// A provider is either the Claude CLI default (`.claudeCLI`, no `command`) or an
/// ACP agent (`.acp`, with a PATH-resolvable spawn `command` argv + optional
/// `env`). **The auth API key is NEVER stored here** — it lives in the Keychain
/// via `ACPCredentialStore`, keyed by `id`. This mirrors the existing split:
/// `ACPAgentConfig` (plain prefs) + `KeychainACPCredentialStore` (secrets).
///
/// `Codable`/`Equatable`/`Sendable` so it persists to `agent-providers.json` and
/// crosses actor boundaries. Stable across schema additions via the
/// `CodingKeys`-agnostic synthesized coder (new optional fields default to nil).
public struct AgentProvider: Codable, Equatable, Sendable, Identifiable {

    /// Stable provider id. The Claude default is `"claude"`; ACP providers use
    /// their catalog id (`"gemini"`, `"hermes"`, …) or a user-chosen id.
    public var id: String

    /// UI label (e.g. "Claude", "Gemini CLI").
    public var label: String

    /// Which backend to drive.
    public var backend: AgentBackendKind

    /// ACP spawn argv (e.g. `["gemini", "--acp"]`). `nil` for `.claudeCLI` (the
    /// CLI backend owns its own argv via `OperationCommand`). `command[0]` is the
    /// PATH-resolvable executable; resolved on the login-shell PATH at spawn time.
    public var command: [String]?

    /// Extra environment merged into the spawn (after app-owned keys). Empty for
    /// Claude (which reads env from `AgentCommandConfig`).
    public var env: [String: String]

    /// Whether the provider appears in the active set. The launcher only ever
    /// selects from enabled providers; a disabled provider is retained so its
    /// config (command/env/key) survives a re-enable.
    public var enabled: Bool

    /// Whether this is the default provider the launcher uses when the user has
    /// not picked one. Exactly one provider SHOULD be default; `AgentProvidersConfig`
    /// enforces the single-default invariant on load/mutate.
    public var isDefault: Bool

    public init(
        id: String,
        label: String,
        backend: AgentBackendKind,
        command: [String]? = nil,
        env: [String: String] = [:],
        enabled: Bool = true,
        isDefault: Bool = false
    ) {
        self.id = id
        self.label = label
        self.backend = backend
        self.command = command
        self.env = env
        self.enabled = enabled
        self.isDefault = isDefault
    }

    /// The Claude CLI default provider. Always id `"claude"`, `.claudeCLI`,
    /// enabled + default + no command. Seeded as the FIRST provider so existing
    /// users (who never opt into ACP) see zero behavior change.
    public static let claudeDefault = AgentProvider(
        id: "claude",
        label: "Claude",
        backend: .claudeCLI,
        command: nil,
        env: [:],
        enabled: true,
        isDefault: true
    )

    /// Claude via the ACP wrapper (`bunx @agentclientprotocol/claude-agent-acp`).
    /// This is the DEFAULT chat provider — it replaces the legacy `claude -p`
    /// CLI path with the official ACP protocol. The CLI provider is retained
    /// but disabled in the seed.
    public static let claudeAcpDefault = AgentProvider(
        id: "claude-acp",
        label: "Claude",
        backend: .acp,
        command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
        env: [:],
        enabled: true,
        isDefault: true
    )

    /// Hermes via ACP (`hermes acp`). Enabled, not default — one of the three
    /// Phase-1 seed providers alongside Claude and OpenCode.
    public static let hermesDefault = AgentProvider(
        id: "hermes",
        label: "Hermes",
        backend: .acp,
        command: ["hermes", "acp"],
        env: [:],
        enabled: true,
        isDefault: false
    )

    /// OpenCode via ACP (`opencode acp`). Enabled, not default — one of the
    /// three Phase-1 seed providers alongside Claude and Hermes.
    public static let opencodeDefault = AgentProvider(
        id: "opencode",
        label: "OpenCode",
        backend: .acp,
        command: ["opencode", "acp"],
        env: [:],
        enabled: true,
        isDefault: false
    )

    /// Build an ACP provider from a discovered catalog agent. Mirrors paseo's
    /// `buildAcpProviderConfigPatch`: the catalog entry's `command` becomes the
    /// provider's spawn argv, and its `id`/`label` carry over. NOT default (the
    /// Claude default stays default); enabled so a discovered agent is usable
    /// immediately. PURE so it is unit-tested without discovery side effects.
    public static func acp(from agent: KnownACPAgent) -> AgentProvider {
        AgentProvider(
            id: agent.id,
            label: agent.label,
            backend: .acp,
            command: agent.command,
            env: [:],
            enabled: true,
            isDefault: false
        )
    }
}
