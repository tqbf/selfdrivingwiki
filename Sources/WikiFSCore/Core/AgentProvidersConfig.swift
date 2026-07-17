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
public struct AgentProvidersConfig: JSONSidecarConfig {

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

    /// The user's favorited models per provider (paseo's per-row star). Keyed by
    /// `AgentProvider.id` → the favorited model ids. Favorites sort to the top of
    /// the composer's model picker — purely a display preference, with NO effect
    /// on routing/selection. Missing key = no favorites for that provider.
    /// Secrets-free; forward-compatible (a pre-favorites file decodes to empty).
    public var favoriteModelIds: [String: [String]]

    /// Per-stage provider/model routing for ACP ingestion (planner/executor/
    /// finalizer). Missing/empty = every stage falls back to
    /// `selectedProvider()` — today's single-backend behavior is unchanged.
    /// Pruned in `normalized()`: an assignment pointing at a deleted or
    /// disabled provider is dropped rather than silently resolved elsewhere.
    public var stageAssignments: [IngestStage: StageAssignment]

    /// Per-provider concurrent ingestion limits for the `QueueEngine`
    /// (Phase 2). Keyed by `AgentProvider.id`. A missing key (or 0) means the
    /// engine uses its default limit of 1. Forward-compatible: a pre-Phase-2
    /// `agent-providers.json` without this key decodes to `[:]`.
    public var maxConcurrent: [String: Int]

    public init(
        providers: [AgentProvider] = [AgentProvider.claudeAcpDefault],
        providerModels: [String: [CachedModelInfo]] = [:],
        selectedModelIds: [String: String] = [:],
        favoriteModelIds: [String: [String]] = [:],
        stageAssignments: [IngestStage: StageAssignment] = [:],
        maxConcurrent: [String: Int] = [:]
    ) {
        let normalizedProviders = AgentProvidersConfig.normalized(providers)
        self.providers = normalizedProviders
        self.providerModels = providerModels
        self.selectedModelIds = selectedModelIds
        self.favoriteModelIds = favoriteModelIds
        // Prune against the NORMALIZED provider set so a stale/disabled
        // assignment never survives construction.
        self.stageAssignments = stageAssignments.filter { _, assignment in
            normalizedProviders.contains(where: { $0.id == assignment.providerId && $0.enabled })
        }
        self.maxConcurrent = maxConcurrent
    }

    // MARK: - Coding (forward-compatible: old files without model caches decode)

    enum CodingKeys: String, CodingKey {
        case providers
        case providerModels
        case selectedModelIds
        case favoriteModelIds
        case stageAssignments
        case maxConcurrent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let normalizedProviders = AgentProvidersConfig.normalized(
            try c.decodeIfPresent([AgentProvider].self, forKey: .providers) ?? [.claudeAcpDefault])
        self.providers = normalizedProviders
        // New optional fields default to empty so a pre-#329 `agent-providers.json`
        // (no model caches) decodes without a migration — "no model selected →
        // agent default" is exactly the legacy behavior.
        self.providerModels = try c.decodeIfPresent([String: [CachedModelInfo]].self, forKey: .providerModels) ?? [:]
        self.selectedModelIds = try c.decodeIfPresent([String: String].self, forKey: .selectedModelIds) ?? [:]
        self.favoriteModelIds = try c.decodeIfPresent([String: [String]].self, forKey: .favoriteModelIds) ?? [:]
        // A file with no `stageAssignments` key (every pre-Phase-1 file) decodes
        // to empty — every stage falls back to `selectedProvider()`.
        let decodedAssignments = try c.decodeIfPresent([IngestStage: StageAssignment].self, forKey: .stageAssignments) ?? [:]
        self.stageAssignments = decodedAssignments.filter { _, assignment in
            normalizedProviders.contains(where: { $0.id == assignment.providerId && $0.enabled })
        }
        // Forward-compatible: pre-Phase-2 files have no `maxConcurrent` key.
        self.maxConcurrent = try c.decodeIfPresent([String: Int].self, forKey: .maxConcurrent) ?? [:]
    }

    /// JSON filename in the App Group container. Distinct from
    /// `AgentCommandConfig.fileName` / `ACPAgentConfig.fileName`.
    public static let fileName = "agent-providers.json"

    // MARK: - Normalization

    /// Enforce the single-default invariant. PURE so it is unit-tested
    /// directly.
    ///
    /// New invariants (Phase 1 — no more forced `claude-acp` insertion):
    /// - `providers.isEmpty` → re-seed all three defaults (Claude, Hermes,
    ///   OpenCode; Claude default).
    /// - At most one `isDefault`: the FIRST one keeps it, the rest are
    ///   demoted.
    /// - If none is default, the FIRST ENABLED provider is promoted.
    static func normalized(_ providers: [AgentProvider]) -> [AgentProvider] {
        if providers.isEmpty {
            return [.claudeAcpDefault, .hermesDefault, .opencodeDefault]
        }
        var list = providers
        // Single-default: keep the first `isDefault == true`, demote the rest.
        var sawDefault = false
        list = list.map { p in
            var p = p
            if p.isDefault {
                if sawDefault { p.isDefault = false } else { sawDefault = true }
            }
            return p
        }
        // If none was default, promote the first ENABLED provider.
        if !sawDefault, let idx = list.firstIndex(where: { $0.enabled }) {
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
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            stageAssignments: stageAssignments,
            maxConcurrent: maxConcurrent)
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
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            stageAssignments: stageAssignments,
            maxConcurrent: maxConcurrent)
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
            selectedModelIds: selections,
            favoriteModelIds: favoriteModelIds,
            stageAssignments: stageAssignments,
            maxConcurrent: maxConcurrent)
    }

    // MARK: - Favorites (#favorites — display-only, paseo per-row star)

    /// Whether `modelId` is favorited for `providerId`. PURE.
    public func isFavoriteModel(_ modelId: String, forProvider providerId: String) -> Bool {
        favoriteModelIds[providerId]?.contains(modelId) ?? false
    }

    /// The favorited model ids for `providerId`, in favorite order. PURE.
    public func favoriteModels(forProvider providerId: String) -> [String] {
        favoriteModelIds[providerId] ?? []
    }

    /// A PURE mutator: returns a NEW config with `modelId`'s favorite state
    /// toggled for `providerId`. Newly-favorited ids append (preserving order);
    /// removing the last favorite drops the provider key. Persisted by the
    /// launcher; the picker re-sorts favorites to the top on the next read.
    public func togglingFavoriteModel(_ modelId: String, forProvider providerId: String) -> AgentProvidersConfig {
        var favorites = favoriteModelIds
        var list = favorites[providerId] ?? []
        if let idx = list.firstIndex(of: modelId) {
            list.remove(at: idx)
        } else {
            list.append(modelId)
        }
        if list.isEmpty {
            favorites.removeValue(forKey: providerId)
        } else {
            favorites[providerId] = list
        }
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favorites,
            stageAssignments: stageAssignments,
            maxConcurrent: maxConcurrent)
    }

    // MARK: - Ingestion stage routing (Phase 1 — core model only)

    /// Resolve the provider + model a stage should use. Falls back to
    /// `(selectedProvider(), selectedModelId(forProvider:))` when the stage has
    /// no assignment, or its assignment was pruned (deleted/disabled provider)
    /// in `normalized()`/`init`. PURE.
    public func resolvedProvider(for stage: IngestStage) -> (provider: AgentProvider, modelId: String?) {
        if let assignment = stageAssignments[stage],
           let provider = provider(id: assignment.providerId),
           provider.enabled {
            let modelId = assignment.modelId ?? selectedModelId(forProvider: provider.id)
            return (provider, modelId)
        }
        let fallback = selectedProvider()
        return (fallback, selectedModelId(forProvider: fallback.id))
    }

    // MARK: - Seed (pure)

    /// Seed the initial config: the three Phase-1 default providers (Claude —
    /// default, Hermes, OpenCode). Discovered agents are not auto-added; the
    /// user opts in via Settings.
    public static func seed(discovered: [DiscoveredACPAgent]) -> AgentProvidersConfig {
        AgentProvidersConfig(providers: [.claudeAcpDefault, .hermesDefault, .opencodeDefault])
    }

    // MARK: - Persistence

    /// Load `agent-providers.json` from `directory`. If missing OR empty, seed
    /// from `seed(discovered:)` (running real PATH discovery) AND persist the
    /// seed so subsequent loads are stable + the user's edits survive. A corrupt
    /// file degrades to the seed too (same fresh-install behavior as
    /// `AgentCommandConfig.load`). Delegates the file read + decode to
    /// `JSONSidecarConfig.load(from:)`.
    public static func loadOrSeed(
        from directory: URL,
        discover: () -> [DiscoveredACPAgent] = { ACPProviderDiscovery.discover() }
    ) -> AgentProvidersConfig {
        if let config = load(from: directory), !config.providers.isEmpty {
            // Preserve the decoded model caches + selections (re-wrapping with
            // only `providers` would wipe them). Re-normalize providers only.
            DebugLog.store("AgentProvidersConfig.loadOrSeed: LOAD providers=\(config.providers.count) hasModelCaches=\(!config.providerModels.isEmpty) hasSelections=\(!config.selectedModelIds.isEmpty)") // TEMP DEBUG
            return AgentProvidersConfig(
                providers: config.providers,
                providerModels: config.providerModels,
                selectedModelIds: config.selectedModelIds,
                favoriteModelIds: config.favoriteModelIds,
                stageAssignments: config.stageAssignments,
                maxConcurrent: config.maxConcurrent)
        }
        // Missing / corrupt / empty → seed + persist.
        DebugLog.store("AgentProvidersConfig.loadOrSeed: SEED (file missing/corrupt/empty)") // TEMP DEBUG
        let seeded = seed(discovered: discover())
        try? seeded.save(to: directory)
        return seeded
    }
}
