import Foundation

/// The persisted list of configured agent providers (slice of #324 — provider
/// model). Mirrors `AgentCommandConfig` / `ACPAgentConfig`'s persistence pattern:
/// atomic JSON in the App Group container, loaded fresh at spawn time. Replaces
/// the slice-3 `useACPBackend` bool + single `ACPAgentConfig` with a LIST of
/// providers the user configures in Settings.
///
/// **Default = Claude:** `loadOrSeed` always seeds `AgentProvider.claudeDefault`
/// first (default + enabled), so existing users see zero behavior change. ACP
/// agents discovered on the login-shell PATH are seeded alongside it (disabled
/// until the user enables + sets them default), so discovery is visible without
/// changing the active backend.
///
/// **Secrets:** the API key for an ACP provider lives in the Keychain via
/// `ACPCredentialStore`, keyed by provider `id` — it is NEVER in this JSON file.
/// This mirrors the existing `ACPAgentConfig` (plain prefs) +
/// `KeychainACPCredentialStore` (secret) split.
public struct AgentProvidersConfig: Codable, Equatable, Sendable {

    /// The configured providers. At least one is always present (the Claude
    /// default). Order is the display order in Settings.
    public var providers: [AgentProvider]

    public init(providers: [AgentProvider] = [AgentProvider.claudeDefault]) {
        self.providers = AgentProvidersConfig.normalized(providers)
    }

    /// JSON filename in the App Group container. Distinct from
    /// `AgentCommandConfig.fileName` / `ACPAgentConfig.fileName`.
    public static let fileName = "agent-providers.json"

    // MARK: - Normalization

    /// Enforce the single-default invariant + always-present Claude. PURE so it
    /// is unit-tested directly.
    ///
    /// If no provider is default, the Claude provider (or the first provider)
    /// becomes default. If multiple are default, the FIRST one keeps it and the
    /// rest are demoted. If Claude is absent it is prepended as the default.
    static func normalized(_ providers: [AgentProvider]) -> [AgentProvider] {
        var list = providers
        // Ensure Claude is present + default-eligible.
        if !list.contains(where: { $0.id == "claude" }) {
            list.insert(.claudeDefault, at: 0)
        }
        // Single-default: keep the first `isDefault == true`, demote the rest.
        var sawDefault = false
        list = list.map { p in
            var p = p
            if p.isDefault {
                if sawDefault { p.isDefault = false } else { sawDefault = true }
            }
            return p
        }
        // If none was default, the Claude provider becomes default.
        if !sawDefault, let idx = list.firstIndex(where: { $0.id == "claude" }) {
            list[idx].isDefault = true
        }
        return list
    }

    // MARK: - Selection

    /// The default provider (the launcher's fallback when the user hasn't picked
    /// one). Falls back to Claude if no provider is marked default (defensive —
    /// `normalized` guarantees one, but a hand-edited file could violate it).
    public var defaultProvider: AgentProvider {
        providers.first(where: { $0.isDefault }) ?? .claudeDefault
    }

    /// The provider to actually launch: the default if enabled, else the first
    /// enabled provider, else Claude. The launcher uses this to pick the backend.
    /// PURE (no spawn side effects) so the selection logic is unit-tested.
    public func selectedProvider() -> AgentProvider {
        let def = defaultProvider
        if def.enabled { return def }
        return providers.first(where: { $0.enabled }) ?? .claudeDefault
    }

    /// Look up a provider by id.
    public func provider(id: String) -> AgentProvider? {
        providers.first(where: { $0.id == id })
    }

    /// Mark the provider with `id` as the default, demoting every other provider
    /// (the single-default invariant — exactly one default after this returns).
    /// PURE + returns a NEW config: callers (the Settings UI, the composer's
    /// provider selector) persist the result via `save(to:)`. No-op (returns a
    /// structurally-equivalent config) if `id` is unknown — preserving the
    /// invariant means never leaving zero defaults.
    ///
    /// The new config is `normalized`, so even a hand-crafted input keeps
    /// exactly one default. Mirrors the inline `setDefault` the Settings view
    /// used to own, now on the model so the composer selector shares it.
    public func settingDefault(id: String) -> AgentProvidersConfig {
        var updated = providers
        for i in updated.indices {
            updated[i].isDefault = (updated[i].id == id)
        }
        return AgentProvidersConfig(providers: updated)
    }

    /// The list of providers the selector surfaces: enabled ones only (the
    /// launcher never selects a disabled provider, and the Settings UI hides
    /// them from its default picker). Kept on the model so the composer
    /// selector and Settings agree on what's pickable.
    public var enabledProviders: [AgentProvider] {
        providers.filter(\.enabled)
    }

    // MARK: - Seed (pure)

    /// Seed the initial config from discovered ACP agents. PURE: no filesystem,
    /// no discovery side effects — callers pass the discovered set in. Used both
    /// by `loadOrSeed` (with a real discovery) and by unit tests (with a stub).
    ///
    /// Claude is ALWAYS first + default + enabled. Each discovered agent becomes
    /// an enabled-but-not-default ACP provider (the user must explicitly make it
    /// default to switch the active backend — preserving "default = Claude").
    public static func seed(discovered: [DiscoveredACPAgent]) -> AgentProvidersConfig {
        var providers: [AgentProvider] = [.claudeDefault]
        // De-dup discovered agents by id (discovery can't return dupes today, but
        // be defensive against a future catalog edit).
        var seen = Set(["claude"])
        for d in discovered where seen.insert(d.agent.id).inserted {
            providers.append(.acp(from: d.agent))
        }
        return AgentProvidersConfig(providers: providers)
    }

    // MARK: - Persistence

    /// Load `agent-providers.json` from `directory`. If missing OR empty, seed
    /// from `seed(discovered:)` (running real PATH discovery) AND persist the
    /// seed so subsequent loads are stable + the user's edits survive. A corrupt
    /// file degrades to the seed too (same fresh-install behavior as
    /// `AgentCommandConfig.load`).
    public static func loadOrSeed(
        from directory: URL,
        discover: () -> [DiscoveredACPAgent] = { ACPProviderDiscovery.discover() }
    ) -> AgentProvidersConfig {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        if let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(AgentProvidersConfig.self, from: data),
           !config.providers.isEmpty {
            return AgentProvidersConfig(providers: config.providers)
        }
        // Missing / corrupt / empty → seed + persist.
        let seeded = seed(discovered: discover())
        try? seeded.save(to: directory)
        return seeded
    }

    /// Persist to `agent-providers.json` in `directory`, atomically,
    /// pretty-printed + sorted keys. Never writes API keys (those are in the
    /// Keychain).
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
