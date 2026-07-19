import Foundation

/// A configured agent provider — the persisted unit the provider Settings UI and
/// the launcher work with (slice of #324 — provider model, modeled on paseo's
/// `providers-section.tsx`).
///
/// The app is ACP-only (`plans/acp-multi-provider.md` Phase 4): every provider
/// spawns via `ACPBackend`, driven by a PATH-resolvable `command` argv +
/// optional `env`. **The auth API key is NEVER stored here** — it lives in the
/// Keychain via `ACPCredentialStore`, keyed by `id`.
///
/// `Codable`/`Equatable`/`Sendable` so it persists to `agent-providers.json` and
/// crosses actor boundaries. Stable across schema additions via the
/// `CodingKeys`-agnostic synthesized coder (new optional fields default to nil).
/// A legacy `"backend"` key (from the pre-Phase-4 `.claudeCLI`/`.acp` split) is
/// simply ignored by the synthesized decoder — old blobs decode fine and now
/// always run via ACP.
public struct AgentProvider: Codable, Equatable, Sendable, Identifiable {

    /// Stable provider id. ACP providers use their catalog id (`"gemini"`,
    /// `"hermes"`, …) or a user-chosen id.
    public var id: String

    /// UI label (e.g. "Claude", "Gemini CLI").
    public var label: String

    /// ACP spawn argv (e.g. `["gemini", "--acp"]`). `command[0]` is the
    /// PATH-resolvable executable; resolved on the login-shell PATH at spawn time.
    public var command: [String]?

    /// Extra environment merged into the spawn (after app-owned keys).
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
        command: [String]? = nil,
        env: [String: String] = [:],
        enabled: Bool = true,
        isDefault: Bool = false
    ) {
        self.id = id
        self.label = label
        self.command = command
        self.env = env
        self.enabled = enabled
        self.isDefault = isDefault
    }

    /// Claude via the ACP wrapper (`bunx @agentclientprotocol/claude-agent-acp`).
    /// This is the DEFAULT chat provider — also the sole seed for a fresh
    /// install (#663: the old Hermes/OpenCode seed statics were removed in
    /// favour of the generic `AddProviderSheet` + `ACPProviderCatalog`
    /// suggestions surface). Kept as a `static let` because
    /// `AgentProvidersConfig.defaultProvider`/`selectedProvider()` fall back
    /// to it when nothing is configured — a defensive safety net for a
    /// hand-edited/corrupt `agent-providers.json`.
    public static let claudeAcpDefault = AgentProvider(
        id: "claude-acp",
        label: "Claude",
        command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
        env: [:],
        enabled: true,
        isDefault: true
    )

    /// Build an ACP provider from a discovered catalog agent. Mirrors paseo's
    /// `buildAcpProviderConfigPatch`: the catalog entry's `command` becomes the
    /// provider's spawn argv, and its `id`/`label` carry over. NOT default (the
    /// default provider stays default); enabled so a discovered agent is usable
    /// immediately. PURE so it is unit-tested without discovery side effects.
    public static func acp(from agent: KnownACPAgent) -> AgentProvider {
        AgentProvider(
            id: agent.id,
            label: agent.label,
            command: agent.command,
            env: [:],
            enabled: true,
            isDefault: false
        )
    }
}
