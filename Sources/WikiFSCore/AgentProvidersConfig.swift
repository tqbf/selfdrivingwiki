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
///
/// **Per-provider model discovery (#329):** two extra secrets-free caches live
/// here so the chat-composer model picker can list each provider's models and
/// remember the user's choice:
/// - `providerModels` — `[providerId: [CachedModelInfo]]`, captured from the
///   agent's own `session/new` response on first chat and mirrored back to the
///   picker. Only public model-routing metadata (id/name/description) — never
///   credentials.
/// - `selectedModelIds` — `[providerId: modelId]`, the user's per-provider
///   model pick. Empty (the default) = "use the agent's default model" → today's
///   behavior is unchanged for existing users.
public struct AgentProvidersConfig: Codable, Equatable, Sendable {

    /// The configured providers. At least one is always present (the Claude
    /// default). Order is the display order in Settings.
    public var providers: [AgentProvider]

    /// Discovered models per provider, captured from the agent's `session/new`
    /// response (`ModelsInfo.availableModels`). Keyed by `AgentProvider.id`.
    /// The chat-composer model picker reads this to populate each provider's
    /// model list (paseo `combined-model-selector` drill-down). Secrets-free.
    /// Missing key = "models discovered on first chat" (the v1 hint).
    public var providerModels: [String: [CachedModelInfo]]

    /// The user's chosen model id per provider, persisted so the next session
    /// re-applies it via `session/set_model`. Keyed by `AgentProvider.id`.
    /// A missing/empty value = "use the agent's default model" (no `setModel`
    /// call) — the app's default state, so existing users see no change.
    public var selectedModelIds: [String: String]

    /// The hardcoded model list for the Claude CLI provider. `ClaudeCLIBackend`
    /// has no ACP model discovery (it drives `claude -p` directly), so the
    /// selector has no captured list to show. These are the `--model` aliases
    /// `WikiOperation` already threads (`opus`/`sonnet`/`haiku`) — seeded into
    /// `providerModels["claude"]` so the provider always has selectable rows.
    /// Selecting one threads it through `--model` (see
    /// `providerHints["cliSelectedModel"]`).
    ///
    /// `opus` is first so it reads as the default tier (it is what
    /// `topLevelModelAlias` resolves to when no selection is set). PURE constant.
    public static let claudeCachedModels: [CachedModelInfo] = [
        CachedModelInfo(modelId: "opus", name: "Opus"),
        CachedModelInfo(modelId: "sonnet", name: "Sonnet"),
        CachedModelInfo(modelId: "haiku", name: "Haiku"),
    ]

    public init(
        providers: [AgentProvider] = [AgentProvider.claudeAcpDefault],
        providerModels: [String: [CachedModelInfo]] = [:],
        selectedModelIds: [String: String] = [:]
    ) {
        self.providers = AgentProvidersConfig.normalized(providers)
        // Guarantee Claude providers always have their hardcoded model list,
        // even for a hand-built config with no providerModels — so the selector
        // never shows an empty Claude submenu. Only inject when the provider is
        // present AND has no cached models (a captured/real list would win).
        // Check `self.providers` (normalized) so a config built without
        // claude-acp still gets its models after normalization injects it —
        // matching `init(from decoder:)` which also checks normalized providers.
        var models = providerModels
        for pid in ["claude-acp", "claude"] {
            if self.providers.contains(where: { $0.id == pid }),
               models[pid]?.isEmpty ?? true {
                models[pid] = Self.claudeCachedModels
            }
        }
        self.providerModels = models
        self.selectedModelIds = selectedModelIds
    }

    // MARK: - Coding (forward-compatible: old files without model caches decode)

    enum CodingKeys: String, CodingKey {
        case providers
        case providerModels
        case selectedModelIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = AgentProvidersConfig.normalized(
            try c.decodeIfPresent([AgentProvider].self, forKey: .providers) ?? [.claudeAcpDefault])
        // New optional fields default to empty so a pre-#329 `agent-providers.json`
        // (no model caches) decodes without a migration — "no model selected →
        // agent default" is exactly the legacy behavior.
        let decodedModels = try c.decodeIfPresent([String: [CachedModelInfo]].self, forKey: .providerModels) ?? [:]
        // Ensure the Claude provider's hardcoded model list is present on load
        // too (so existing users with an older agent-providers.json also see
        // selectable Claude rows). Only inject when absent/empty.
        var models = decodedModels
        for pid in ["claude-acp", "claude"] {
            if self.providers.contains(where: { $0.id == pid }),
               models[pid]?.isEmpty ?? true {
                models[pid] = Self.claudeCachedModels
            }
        }
        self.providerModels = models
        self.selectedModelIds = try c.decodeIfPresent([String: String].self, forKey: .selectedModelIds) ?? [:]
    }

    /// JSON filename in the App Group container. Distinct from
    /// `AgentCommandConfig.fileName` / `ACPAgentConfig.fileName`.
    public static let fileName = "agent-providers.json"

    // MARK: - Normalization

    /// Enforce the single-default invariant + always-present Claude. PURE so it
    /// is unit-tested directly.
    ///
    /// If no provider is default, the `claude-acp` provider (or the first
    /// provider) becomes default. If multiple are default, the FIRST one keeps
    /// it and the rest are demoted. If `claude-acp` is absent it is prepended
    /// as the default (the app always has a working Claude path).
    static func normalized(_ providers: [AgentProvider]) -> [AgentProvider] {
        var list = providers
        // Ensure claude-acp is present + default-eligible (the app's canonical
        // Claude path).
        if !list.contains(where: { $0.id == "claude-acp" }) {
            list.insert(.claudeAcpDefault, at: 0)
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
        // If none was default, the claude-acp provider becomes default.
        if !sawDefault, let idx = list.firstIndex(where: { $0.id == "claude-acp" }) {
            list[idx].isDefault = true
        }
        return list
    }

    // MARK: - Selection

    /// The default provider (the launcher's fallback when the user hasn't picked
    /// one). Falls back to Claude if no provider is marked default (defensive —
    /// `normalized` guarantees one, but a hand-edited file could violate it).
    public var defaultProvider: AgentProvider {
        providers.first(where: { $0.isDefault }) ?? .claudeAcpDefault
    }

    /// The provider to actually launch: the default if enabled, else the first
    /// enabled provider, else Claude. The launcher uses this to pick the backend.
    /// PURE (no spawn side effects) so the selection logic is unit-tested.
    public func selectedProvider() -> AgentProvider {
        let def = defaultProvider
        if def.enabled { return def }
        return providers.first(where: { $0.enabled }) ?? .claudeAcpDefault
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
        // Carry over the per-provider model caches + selections (don't wipe them
        // when only the default provider changes).
        return AgentProvidersConfig(
            providers: updated,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds)
    }

    /// The list of providers the selector surfaces: enabled ones only (the
    /// launcher never selects a disabled provider, and the Settings UI hides
    /// them from its default picker). Kept on the model so the composer
    /// selector and Settings agree on what's pickable.
    public var enabledProviders: [AgentProvider] {
        providers.filter(\.enabled)
    }

    // MARK: - Per-provider model cache + selection (#329)

    /// The cached models for `providerId` (captured from the agent's
    /// `session/new`). Empty when none are cached yet → the picker shows its
    /// "models discovered on first chat" hint (v1 capture-from-session; on-demand
    /// probing is a later enhancement). PURE.
    public func cachedModels(forProvider providerId: String) -> [CachedModelInfo] {
        providerModels[providerId] ?? []
    }

    /// The user's selected model id for `providerId`, or `nil` when none is set
    /// ("use the agent's default model"). PURE. Read by `ACPBackend.start` to
    /// decide whether to send `session/set_model`.
    public func selectedModelId(forProvider providerId: String) -> String? {
        guard let id = selectedModelIds[providerId], !id.isEmpty else { return nil }
        return id
    }

    /// A PURE mutator: returns a NEW config with `providerId`'s cached models
    /// replaced by `models`. Called by the launcher after `backend.start`
    /// captures the agent's advertised `ModelsInfo`. The picker reads the result
    /// next load. Never writes secrets (only `CachedModelInfo`).
    public func settingCachedModels(_ models: [CachedModelInfo], forProvider providerId: String) -> AgentProvidersConfig {
        var cache = providerModels
        if models.isEmpty {
            cache.removeValue(forKey: providerId)
        } else {
            cache[providerId] = models
        }
        DebugLog.store("AgentProvidersConfig.settingCachedModels: provider=\(providerId) count=\(models.isEmpty ? 0 : models.count)") // TEMP DEBUG
        return AgentProvidersConfig(
            providers: providers,
            providerModels: cache,
            selectedModelIds: selectedModelIds)
    }

    /// A PURE mutator: returns a NEW config with the user's model selection for
    /// `providerId` set (or cleared when `modelId` is nil/empty). Called by the
    /// chat-composer model picker; persisted by the launcher. A nil/empty
    /// selection = "use the agent's default" → today's behavior is unchanged.
    public func settingSelectedModel(_ modelId: String?, forProvider providerId: String) -> AgentProvidersConfig {
        var selections = selectedModelIds
        if let modelId, !modelId.isEmpty {
            selections[providerId] = modelId
        } else {
            selections.removeValue(forKey: providerId)
        }
        DebugLog.store("AgentProvidersConfig.settingSelectedModel: provider=\(providerId) modelId=\(modelId ?? "nil")") // TEMP DEBUG
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selections)
    }

    // MARK: - Seed (pure)

    /// Seed the initial config from discovered ACP agents. PURE: no filesystem,
    /// no discovery side effects — callers pass the discovered set in. Used both
    /// by `loadOrSeed` (with a real discovery) and by unit tests (with a stub).
    ///
    /// `claude-acp` (Claude via the ACP wrapper) is ALWAYS first + default +
    /// enabled. The legacy `claude` CLI provider is included but DISABLED (the
    /// `-p` system is superseded by ACP). Each discovered agent becomes an
    /// enabled-but-not-default ACP provider.
    public static func seed(discovered: [DiscoveredACPAgent]) -> AgentProvidersConfig {
        var providers: [AgentProvider] = [.claudeAcpDefault]
        // Include the legacy CLI provider, disabled.
        var legacy = AgentProvider.claudeDefault
        legacy.enabled = false
        legacy.isDefault = false
        providers.append(legacy)
        // De-dup discovered agents by id (discovery can't return dupes today, but
        // be defensive against a future catalog edit). Skip claude-acp/claude
        // (already seeded above).
        var seen = Set(["claude-acp", "claude"])
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
            // Preserve the decoded model caches + selections (re-wrapping with
            // only `providers` would wipe them). Re-normalize providers only.
            DebugLog.store("AgentProvidersConfig.loadOrSeed: LOAD providers=\(config.providers.count) hasModelCaches=\(!config.providerModels.isEmpty) hasSelections=\(!config.selectedModelIds.isEmpty)") // TEMP DEBUG
            return AgentProvidersConfig(
                providers: config.providers,
                providerModels: config.providerModels,
                selectedModelIds: config.selectedModelIds)
        }
        // Missing / corrupt / empty → seed + persist.
        DebugLog.store("AgentProvidersConfig.loadOrSeed: SEED (file missing/corrupt/empty)") // TEMP DEBUG
        let seeded = seed(discovered: discover())
        try? seeded.save(to: directory)
        return seeded
    }

    /// Persist to `agent-providers.json` in `directory`, atomically,
    /// pretty-printed + sorted keys. Never writes API keys (those are in the
    /// Keychain).
    public func save(to directory: URL) throws {
        DebugLog.store("AgentProvidersConfig.save: providers=\(providers.count) default=\(defaultProvider.id) modelCaches=\(providerModels.count) selections=\(selectedModelIds.count)") // TEMP DEBUG
        let url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
