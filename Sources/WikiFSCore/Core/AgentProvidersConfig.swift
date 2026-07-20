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

    /// Per-provider concurrent ingestion limits for the `QueueEngine`
    /// (Phase 2). Keyed by `AgentProvider.id`. A missing key (or 0) means the
    /// engine uses its default limit of 1. Forward-compatible: a pre-Phase-2
    /// `agent-providers.json` without this key decodes to `[:]`.
    public var maxConcurrent: [String: Int]

    /// Per-operation default provider id overrides (issue: per-op-provider).
    /// When `nil`, the operation falls back to `defaultProvider` (the provider
    /// marked `isDefault == true`). When set to an id that no longer matches
    /// any provider (the provider was deleted), the resolver ALSO falls back
    /// to `defaultProvider` — there are no dangling references.
    ///
    /// `nil` is the legacy state: a pre-existing `agent-providers.json` without
    /// these keys decodes to all-`nil`, so every operation routes to
    /// `defaultProvider` exactly as before — no migration, no behavior change
    /// for existing users.
    public var chatProviderId: String?
    public var ingestProviderId: String?
    public var lintProviderId: String?

    public init(
        providers: [AgentProvider] = [AgentProvider.claudeAcpDefault],
        providerModels: [String: [CachedModelInfo]] = [:],
        selectedModelIds: [String: String] = [:],
        favoriteModelIds: [String: [String]] = [:],
        maxConcurrent: [String: Int] = [:],
        chatProviderId: String? = nil,
        ingestProviderId: String? = nil,
        lintProviderId: String? = nil
    ) {
        let normalizedProviders = AgentProvidersConfig.normalized(providers)
        self.providers = normalizedProviders
        self.providerModels = providerModels
        self.selectedModelIds = selectedModelIds
        self.favoriteModelIds = favoriteModelIds
        self.maxConcurrent = maxConcurrent
        self.chatProviderId = chatProviderId
        self.ingestProviderId = ingestProviderId
        self.lintProviderId = lintProviderId
    }

    // MARK: - Coding (forward-compatible: old files without model caches decode)

    enum CodingKeys: String, CodingKey {
        case providers
        case providerModels
        case selectedModelIds
        case favoriteModelIds
        case maxConcurrent
        case chatProviderId
        case ingestProviderId
        case lintProviderId
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
        // Forward-compatible: pre-Phase-2 files have no `maxConcurrent` key.
        self.maxConcurrent = try c.decodeIfPresent([String: Int].self, forKey: .maxConcurrent) ?? [:]
        // Forward-compatible: pre-per-op-provider files have no per-operation
        // provider id keys. nil → "use defaultProvider" = legacy behavior.
        self.chatProviderId = try c.decodeIfPresent(String.self, forKey: .chatProviderId)
        self.ingestProviderId = try c.decodeIfPresent(String.self, forKey: .ingestProviderId)
        self.lintProviderId = try c.decodeIfPresent(String.self, forKey: .lintProviderId)
        // NOTE: a legacy `stageAssignments` key in `agent-providers.json` is
        // silently ignored — it is not in `CodingKeys`, so `JSONDecoder`
        // skips it. The per-stage assignment feature was removed (#604): every
        // ingest stage (planner/executor/finalizer) now resolves to the app
        // default provider + its `selectedModelId`. The stale key is naturally
        // migrated away on the next save (the field is gone).
    }

    /// JSON filename in the App Group container. Distinct from
    /// `AgentCommandConfig.fileName` / `ACPAgentConfig.fileName`.
    public static let fileName = "agent-providers.json"

    // MARK: - Normalization

    /// Enforce the single-default invariant. PURE so it is unit-tested
    /// directly.
    ///
    /// New invariants (#663 — generic Custom-ACP):
    /// - `providers.isEmpty` → seed `[claudeAcpDefault]` ONLY (the old
    ///   three-default Hermesc+OpenCode seed was removed; the catalog-driven
    ///   `AddProviderSheet` replaces it for first-run discoverability).
    /// - At most one `isDefault`: the FIRST one keeps it, the rest are
    ///   demoted.
    /// - If none is default, the FIRST ENABLED provider is promoted.
    static func normalized(_ providers: [AgentProvider]) -> [AgentProvider] {
        if providers.isEmpty {
            return [.claudeAcpDefault]
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

    // MARK: - Per-operation provider resolution (per-op-provider)

    /// The provider to launch for **chat** (`startInteractiveQuery`). When
    /// `chatProviderId` is nil OR no longer matches a configured provider (the
    /// provider was deleted), falls back to `defaultProvider` — there are no
    /// dangling references. PURE so it is unit-tested directly; called fresh at
    /// spawn time so a Settings change applies on the next chat.
    public func providerForChat() -> AgentProvider {
        chatProviderId.flatMap { provider(id: $0) } ?? defaultProvider
    }

    /// The provider to launch for **ingest** (single-session `run()` for the
    /// `.ingest` request + the multi-phase `runACPIngestPlannerExecutors`
    /// path). Same fall-back semantics as `providerForChat()`.
    public func providerForIngest() -> AgentProvider {
        ingestProviderId.flatMap { provider(id: $0) } ?? defaultProvider
    }

    /// The provider to launch for **lint** (`run()` for `.lint` / `.lintPage`
    /// requests). Same fall-back semantics as `providerForChat()`.
    public func providerForLint() -> AgentProvider {
        lintProviderId.flatMap { provider(id: $0) } ?? defaultProvider
    }

    /// A PURE mutator: returns a NEW config with the chat operation pinned to
    /// `id` (or un-pinned when `id` is nil/empty, restoring the legacy "use
    /// defaultProvider" behavior). Persists via the launcher wrapper
    /// `setChatProvider(id:)`; the Settings UI binds to it directly. NEVER
    /// validates that `id` exists — the resolver falls back to
    /// `defaultProvider` when a pinned id is later deleted, so accepting an
    /// unknown id here is safe and means a re-add of the same id later just
    /// starts working again. Mirrors `settingDefault(id:)`'s carry-everything-
    /// else-through shape.
    public func settingChatProvider(id: String?) -> AgentProvidersConfig {
        let normalized = (id?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        DebugLog.store("AgentProvidersConfig.settingChatProvider: id=\(normalized ?? "nil")")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            chatProviderId: normalized,
            ingestProviderId: ingestProviderId,
            lintProviderId: lintProviderId)
    }

    /// A PURE mutator: returns a NEW config with the ingest operation pinned
    /// to `id` (or un-pinned when nil/empty). See `settingChatProvider(id:)`
    /// for the semantics.
    public func settingIngestProvider(id: String?) -> AgentProvidersConfig {
        let normalized = (id?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        DebugLog.store("AgentProvidersConfig.settingIngestProvider: id=\(normalized ?? "nil")")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            chatProviderId: chatProviderId,
            ingestProviderId: normalized,
            lintProviderId: lintProviderId)
    }

    /// A PURE mutator: returns a NEW config with the lint operation pinned
    /// to `id` (or un-pinned when nil/empty). See `settingChatProvider(id:)`
    /// for the semantics.
    public func settingLintProvider(id: String?) -> AgentProvidersConfig {
        let normalized = (id?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        DebugLog.store("AgentProvidersConfig.settingLintProvider: id=\(normalized ?? "nil")")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            chatProviderId: chatProviderId,
            ingestProviderId: ingestProviderId,
            lintProviderId: normalized)
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
        // Carry over the per-provider model caches + selections + the
        // per-operation provider id overrides (don't wipe them when only the
        // default provider changes). The per-op overrides are NOT re-pointed:
        // if chat was pinned to id="claude-acp" and the user changes the
        // default to "gemini", the chat override still routes chat to
        // claude-acp — that is the whole point of an explicit per-op override.
        return AgentProvidersConfig(
            providers: updated,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            chatProviderId: chatProviderId,
            ingestProviderId: ingestProviderId,
            lintProviderId: lintProviderId)
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
        DebugLog.store("AgentProvidersConfig.settingCachedModels: provider=\(providerId) count=\(models.isEmpty ? 0 : models.count)")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: cache,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            chatProviderId: chatProviderId,
            ingestProviderId: ingestProviderId,
            lintProviderId: lintProviderId)
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
        DebugLog.store("AgentProvidersConfig.settingSelectedModel: provider=\(providerId) modelId=\(modelId ?? "nil")")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selections,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            chatProviderId: chatProviderId,
            ingestProviderId: ingestProviderId,
            lintProviderId: lintProviderId)
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
            maxConcurrent: maxConcurrent,
            chatProviderId: chatProviderId,
            ingestProviderId: ingestProviderId,
            lintProviderId: lintProviderId)
    }

    // MARK: - Seed (pure)

    /// Seed the initial config: the Claude ACP default ONLY (#663 dropped
    /// the Hermes/OpenCode seed statics — first-run discovery now goes
    /// through the `AddProviderSheet` + `ACPProviderCatalog` suggestions
    /// surface, not through seeding). Discovered agents are not auto-added;
    /// the user opts in via Settings.
    ///
    /// **Default model for the default provider:** the shipped `claude-acp`
    /// seed is paired with `selectedModelIds["claude-acp"] = "sonnet"` so a
    /// fresh install can spawn chat/ingest immediately. The launcher's
    /// `SpawnModelGuard` (see `Sources/WikiFSEngine/SpawnModelGuard.swift`)
    /// refuses to spawn without an explicit `selectedModelId`; without this
    /// seed entry a fresh install would hit a hard circularity (you must
    /// spawn to discover models, but the guard refuses to spawn until a model
    /// is picked). `"sonnet"` is claude-acp's standard short-name advertised on
    /// the first live `session/new`. See `tmp/ingestion-stall-diagnosis.md`.
    public static func seed(discovered: [DiscoveredACPAgent]) -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [.claudeAcpDefault],
            selectedModelIds: ["claude-acp": "sonnet"])
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
            DebugLog.store("AgentProvidersConfig.loadOrSeed: LOAD providers=\(config.providers.count) hasModelCaches=\(!config.providerModels.isEmpty) hasSelections=\(!config.selectedModelIds.isEmpty)")
            var selectedModelIds = config.selectedModelIds
            // Backfill: upgrade-safety for existing `claude-acp`-default installs
            // (which silently defaulted to Sonnet before the
            // `SpawnModelGuard` existed). Only injects when `claude-acp` is the
            // default provider AND no model is picked for it — non-default
            // providers (Hermes/OpenCode/custom) and any deliberately-emptied
            // non-default provider are unaffected, so the guard still refuses
            // spawn for the actual diagnosed-bug state (a non-default provider
            // set as default with no selection). See
            // `tmp/ingestion-stall-diagnosis.md` and
            // `SpawnModelGuard.validate(provider:modelId:)`.
            if config.providers.first(where: { $0.isDefault && $0.id == "claude-acp" }) != nil,
               config.selectedModelId(forProvider: "claude-acp") == nil {
                DebugLog.store("AgentProvidersConfig.loadOrSeed: BACKFILL claude-acp default-model='sonnet'")
                selectedModelIds = selectedModelIds.merging(
                    ["claude-acp": "sonnet"],
                    uniquingKeysWith: { current, _ in current })
            }
            return AgentProvidersConfig(
                providers: config.providers,
                providerModels: config.providerModels,
                selectedModelIds: selectedModelIds,
                favoriteModelIds: config.favoriteModelIds,
                maxConcurrent: config.maxConcurrent,
                chatProviderId: config.chatProviderId,
                ingestProviderId: config.ingestProviderId,
                lintProviderId: config.lintProviderId)
        }
        // Missing / corrupt / empty → seed + persist.
        DebugLog.store("AgentProvidersConfig.loadOrSeed: SEED (file missing/corrupt/empty)")
        let seeded = seed(discovered: discover())
        do {
            try seeded.save(to: directory)
        } catch {
            // Per house rules — never bare `try?`. Persisting the seed is
            // best-effort here (the file may be on a read-only mount during
            // first-launch discovery); the in-memory seed is returned either
            // way so the launcher can continue, and the next write attempt
            // (Settings edit) surfaces a real error if the dir is unwritable.
            DebugLog.store("AgentProvidersConfig.loadOrSeed: failed to persist seed — \(error.localizedDescription)")
        }
        return seeded
    }
}
