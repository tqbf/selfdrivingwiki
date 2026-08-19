import Foundation
import Darwin

public extension Notification.Name {
    /// Emitted after `agent-providers.json` is atomically replaced so cached
    /// chat-composer state can refresh outside SwiftUI's render path.
    static let agentProvidersConfigDidChange = Notification.Name(
        "org.selfdrivingwiki.agentProvidersConfigDidChange"
    )
}

/// Serializes read-modify-write operations on `agent-providers.json` in this
/// process and across processes that share the App Group container.
public actor AgentProvidersConfigStore {
    public static let darwinNotificationName = "org.selfdrivingwiki.agentProvidersConfigDidChange"

    private static let retryBackoff: Duration = .milliseconds(25)
    private static let inProcessGate = AgentProvidersConfigInProcessGate()

    private let directory: URL
    private let write: @Sendable (AgentProvidersConfig, URL) throws -> Void
    private let postLocal: @Sendable (URL) -> Void
    private let postDarwin: @Sendable () -> Void
    private let lockTimeout: Duration

    public init(
        directory: URL,
        lockTimeout: Duration = .seconds(5),
        write: @escaping @Sendable (AgentProvidersConfig, URL) throws -> Void = { config, directory in
            try config.writeAtomically(to: directory)
        },
        postLocal: @escaping @Sendable (URL) -> Void = { directory in
            NotificationCenter.default.post(
                name: .agentProvidersConfigDidChange,
                object: directory.standardizedFileURL)
        },
        postDarwin: @escaping @Sendable () -> Void = {
            DarwinNotifier.postAgentProvidersConfigChange()
        }
    ) {
        self.directory = directory.standardizedFileURL
        self.write = write
        self.postLocal = postLocal
        self.postDarwin = postDarwin
        self.lockTimeout = lockTimeout
    }

    /// Applies only fields changed between a caller's prior snapshot and its
    /// updated snapshot. Unchanged fields retain the newest locked value, so
    /// disjoint app/daemon edits survive concurrent SwiftUI save helpers.
    public func mergeMutation(
        from prior: AgentProvidersConfig,
        to updated: AgentProvidersConfig
    ) async throws -> AgentProvidersConfig {
        try await mutate { latest in
            AgentProvidersConfig(
                providers: prior.providers == updated.providers ? latest.providers : updated.providers,
                providerModels: prior.providerModels == updated.providerModels ? latest.providerModels : updated.providerModels,
                selectedModelIds: prior.selectedModelIds == updated.selectedModelIds ? latest.selectedModelIds : updated.selectedModelIds,
                favoriteModelIds: prior.favoriteModelIds == updated.favoriteModelIds ? latest.favoriteModelIds : updated.favoriteModelIds,
                maxConcurrent: prior.maxConcurrent == updated.maxConcurrent ? latest.maxConcurrent : updated.maxConcurrent,
                ingestStageModelIds: prior.ingestStageModelIds == updated.ingestStageModelIds ? latest.ingestStageModelIds : updated.ingestStageModelIds,
                stageProviderIds: prior.stageProviderIds == updated.stageProviderIds ? latest.stageProviderIds : updated.stageProviderIds,
                catalogObservations: prior.catalogObservations == updated.catalogObservations ? latest.catalogObservations : updated.catalogObservations,
                generation: latest.generation)
        }
    }

    /// Reloads the newest committed value while holding the kernel lock, applies
    /// one synchronous value mutation, commits exactly one next generation, then
    /// releases both locks before notifying observers.
    public func mutate(
        _ body: @Sendable (AgentProvidersConfig) throws -> AgentProvidersConfig
    ) async throws -> AgentProvidersConfig {
        let descriptor = try await acquireLock()
        let committed: AgentProvidersConfig
        do {
            let current = AgentProvidersConfig.load(from: directory)
                ?? AgentProvidersConfig.seed(discovered: [])
            var updated = try body(current)
            updated.generation = current.generation &+ 1
            try write(updated, directory)
            committed = updated
        } catch {
            await releaseLock(descriptor)
            throw error
        }
        await releaseLock(descriptor)
        // Ordering is deliberate: observers can always reopen the finished file.
        postLocal(directory)
        postDarwin()
        return committed
    }

    private var lockURL: URL {
        directory.appendingPathComponent("\(AgentProvidersConfig.fileName).lock", isDirectory: false)
    }

    private func acquireLock() async throws -> Int32 {
        let key = lockURL.path
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: lockTimeout)
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw AgentProvidersConfigStoreError.lockAcquisitionTimedOut
            }
            guard await Self.inProcessGate.tryAcquire(key) else {
                try await Task.sleep(for: Self.retryBackoff)
                continue
            }
            do {
                let descriptor = try openLockFile()
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    let code = errno
                    close(descriptor)
                    if code == EWOULDBLOCK || code == EAGAIN {
                        await Self.inProcessGate.release(key)
                        try await Task.sleep(for: Self.retryBackoff)
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                return descriptor
            } catch {
                await Self.inProcessGate.release(key)
                throw error
            }
        }
    }

    private func openLockFile() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = lockURL.path.withCString {
            open($0, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) async {
        let unlockResult = flock(descriptor, LOCK_UN)
        let closeResult = close(descriptor)
        if unlockResult != 0 || closeResult != 0 {
            DebugLog.store("AgentProvidersConfigStore: lock release failed.")
        }
        let key = lockURL.path
        await Self.inProcessGate.release(key)
    }
}

public enum AgentProvidersConfigStoreError: Error, Equatable, Sendable {
    case lockAcquisitionTimedOut
}

private actor AgentProvidersConfigInProcessGate {
    private var heldPaths: Set<String> = []

    func tryAcquire(_ path: String) -> Bool { heldPaths.insert(path).inserted }
    func release(_ path: String) { heldPaths.remove(path) }
}

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
    public var selectedModelIds: [String: ModelID]

    /// The user's favorited models per provider (paseo's per-row star). Keyed by
    /// `AgentProvider.id` → the favorited model ids. Favorites sort to the top of
    /// the composer's model picker — purely a display preference, with NO effect
    /// on routing/selection. Missing key = no favorites for that provider.
    /// Secrets-free; forward-compatible (a pre-favorites file decodes to empty).
    public var favoriteModelIds: [String: [ModelID]]

    /// Per-provider concurrent ingestion limits for the `QueueEngine`
    /// (Phase 2). Keyed by `AgentProvider.id`. A missing key (or 0) means the
    /// engine uses its default limit of 1. Forward-compatible: a pre-Phase-2
    /// `agent-providers.json` without this key decodes to `[:]`.
    public var maxConcurrent: [String: Int]

    /// Per-stage MODEL overrides. Keyed by stage name — the ingest stages
    /// (`"planner"`, `"executor"`, `"finalizer"` — see `ACPIngestStage`) PLUS
    /// the operation-level stages (`"chat"`, `"lint"`) introduced by the
    /// agent-settings-tabs plan. Each value is a model id FOR THE STAGE'S
    /// RESOLVED PROVIDER (see `provider(forStage:)`). A missing or empty value
    /// falls back to that provider's `selectedModelId(forProvider:)`. The map
    /// name retains the historical `ingest` prefix for backward-compat (the
    /// persisted JSON key is unchanged); the chat/lint keys ride the same
    /// string-keyed map. Do NOT "clean up" the non-ingest keys — they are
    /// load-bearing (`plans/agent-settings-tabs.md`). Forward-compatible: a
    /// pre-per-stage `agent-providers.json` without this key decodes to `[:]`
    /// → every stage uses the provider's `selectedModelId`. See
    /// `plans/per-stage-model-selection.md`.
    public var ingestStageModelIds: [String: ModelID]

    /// Per-stage PROVIDER overrides. Keyed by stage name (`"chat"`,
    /// `"planner"`, `"executor"`, `"finalizer"`, `"lint"`). Value = provider
    /// id. Missing/empty (`""`) = "use the global default provider"
    /// (`selectedProvider()`). This lets the user pin a different PROVIDER per
    /// operation/stage (Chat / Ingestion / Lint tabs in Settings), on top of
    /// the per-stage MODEL overrides in `ingestStageModelIds`. Forward-
    /// compatible: a pre-this-change `agent-providers.json` without this key
    /// decodes to `[:]` → every stage uses the global default. See
    /// `plans/agent-settings-tabs.md`.
    public var stageProviderIds: [String: ProviderID]

    /// Complete successful catalog observations keyed by configured provider ID.
    /// Missing data is expected for legacy files and means identity is unknown.
    public var catalogObservations: [String: ACPProviderCatalogObservation]

    /// Monotonic sidecar revision. The locked mutation store increments this
    /// exactly once for every committed logical mutation.
    public var generation: UInt64

    public init(
        providers: [AgentProvider] = [AgentProvider.claudeAcpDefault],
        providerModels: [String: [CachedModelInfo]] = [:],
        selectedModelIds: [String: ModelID] = [:],
        favoriteModelIds: [String: [ModelID]] = [:],
        maxConcurrent: [String: Int] = [:],
        ingestStageModelIds: [String: ModelID] = [:],
        stageProviderIds: [String: ProviderID] = [:],
        catalogObservations: [String: ACPProviderCatalogObservation] = [:],
        generation: UInt64 = 0
    ) {
        let normalizedProviders = AgentProvidersConfig.normalized(providers)
        self.providers = normalizedProviders
        self.providerModels = providerModels
        self.selectedModelIds = selectedModelIds
        self.favoriteModelIds = favoriteModelIds
        self.maxConcurrent = maxConcurrent
        self.ingestStageModelIds = ingestStageModelIds
        self.stageProviderIds = stageProviderIds
        self.catalogObservations = catalogObservations
        self.generation = generation
    }

    // MARK: - Coding (forward-compatible: old files without model caches decode)

    enum CodingKeys: String, CodingKey {
        case providers
        case providerModels
        case selectedModelIds
        case favoriteModelIds
        case maxConcurrent
        case ingestStageModelIds
        case stageProviderIds
        case catalogObservations
        case generation
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
        self.selectedModelIds = try c.decodeIfPresent([String: ModelID].self, forKey: .selectedModelIds) ?? [:]
        self.favoriteModelIds = try c.decodeIfPresent([String: [ModelID]].self, forKey: .favoriteModelIds) ?? [:]
        // Forward-compatible: pre-Phase-2 files have no `maxConcurrent` key.
        self.maxConcurrent = try c.decodeIfPresent([String: Int].self, forKey: .maxConcurrent) ?? [:]
        // Forward-compatible: pre-per-stage files have no `ingestStageModelIds`
        // key. `[:]` → every stage uses the provider's `selectedModelId`
        // (the legacy #604 collapsed behavior — no migration, no behavior
        // change for existing users).
        self.ingestStageModelIds = try c.decodeIfPresent([String: ModelID].self, forKey: .ingestStageModelIds) ?? [:]
        // Forward-compatible: pre-agent-settings-tabs files have no
        // `stageProviderIds` key. `[:]` → every stage uses the global default
        // provider (the legacy behavior — no migration, no behavior change).
        self.stageProviderIds = try c.decodeIfPresent([String: ProviderID].self, forKey: .stageProviderIds) ?? [:]
        self.catalogObservations = try c.decodeIfPresent(
            [String: ACPProviderCatalogObservation].self, forKey: .catalogObservations) ?? [:]
        self.generation = try c.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        // NOTE: a legacy `stageAssignments` key in `agent-providers.json` is
        // silently ignored — it is not in `CodingKeys`, so `JSONDecoder`
        // skips it. The original per-stage assignment feature was removed
        // (#604) and is now RESTORED as `ingestStageModelIds`
        // (per-stage MODEL selection within ONE provider — not per-stage
        // provider routing). A legacy `chatProviderId` / `ingestProviderId`
        // / `lintProviderId` key from the removed #704 per-operation provider
        // pin layer is likewise silently ignored (those fields are gone).
        // The stale keys are naturally migrated away on the next save.
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

    /// PURE mutator: returns a NEW config with `providers` replaced (re-
    /// normalized by `init`) and EVERY other field carried through unchanged.
    /// Use this from call sites that only want to change the providers list —
    /// the memberwise init's defaulted fields silently drop `maxConcurrent`
    /// AND `ingestStageModelIds`, which is the pre-existing bug
    /// `plans/inline-models-and-remove-permissions-tab-v2.md` §4f fixes.
    /// Mirrors the carry-everything-through shape of `settingDefault(id:)` /
    /// `settingIngestStageModel(_:forStage:)`.
    public func replacingProviders(_ providers: [AgentProvider]) -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: ingestStageModelIds,
            stageProviderIds: stageProviderIds,
            catalogObservations: catalogObservations,
            generation: generation)
    }

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
    public func provider(id: ProviderID) -> AgentProvider? {
        providers.first(where: { $0.id == id })
    }

    // MARK: - Per-stage provider + model resolution (agent-settings-tabs plan)

    /// Resolve the concrete provider for a stage: the stage's pinned provider
    /// when set + enabled, else the global `selectedProvider()`. The stage
    /// key is one of `"chat"`, `"planner"`, `"executor"`, `"finalizer"`,
    /// `"lint"`. PURE so it is unit-tested without a subprocess. A disabled
    /// pin falls back to the default (the launcher never selects a disabled
    /// provider). See `plans/agent-settings-tabs.md` §3.
    /// `chatOverrideProviderId` is the per-chat model override
    /// (`ChatSummary.modelProviderId`) — when set + enabled, it outranks even
    /// the stage pin. `nil` (every non-chat call site, and a chat with no
    /// override) preserves today's stage-pin-then-global-default resolution.
    public func provider(forStage stage: String, chatOverrideProviderId: ProviderID? = nil) -> AgentProvider {
        if let chatOverrideProviderId, !chatOverrideProviderId.rawValue.isEmpty,
           let p = provider(id: chatOverrideProviderId), p.enabled {
            return p
        }
        if let pinnedId = stageProviderIds[stage],
           !pinnedId.rawValue.isEmpty,
           let p = provider(id: pinnedId), p.enabled {
            return p
        }
        return selectedProvider()
    }

    /// #727: the ordered provider chain for a stage — the stage's resolved
    /// provider FIRST, then the OTHER enabled providers in display order
    /// (excluding duplicates of the first). The launcher walks this chain,
    /// skipping providers marked dead by the `QuotaFallbackCoordinator`.
    /// PURE so the chain is unit-tested without a subprocess.
    ///
    /// If only one provider is enabled (the common case today), the chain is
    /// `[first]` and there is no fallback — quota exhaustion fails the item.
    public func providerChain(forStage stage: String) -> [AgentProvider] {
        let first = provider(forStage: stage)
        let others = enabledProviders.filter { $0.id != first.id }
        return [first] + others
    }

    /// Resolve the concrete model id for a stage using the stage-resolved
    /// provider (`provider(forStage:)`). Returns the stage's pinned model id
    /// when set + non-empty; otherwise falls back to that provider's
    /// `selectedModelId`. PURE. This is the convenience wrapper that composes
    /// `provider(forStage:)` + `modelId(forStage:fallbackProvider:)` — the
    /// launcher's chat/lint/ingest sites call it so both the provider pin and
    /// the model override resolve through one seam.
    /// `chatOverrideProviderId`/`chatOverrideModelId` mirror
    /// `provider(forStage:chatOverrideProviderId:)`'s override tier: when a
    /// per-chat provider override is active, the model resolves WITHIN that
    /// override (the override's own model id, else that provider's
    /// `selectedModelId`) — the stage's model pin (`ingestStageModelIds`) is
    /// bypassed, matching "the per-chat pick replaces the stage's resolution
    /// entirely, not just the provider half of it."
    public func modelId(
        forStage stage: String,
        chatOverrideProviderId: ProviderID? = nil, chatOverrideModelId: ModelID? = nil
    ) -> ModelID? {
        let p = provider(forStage: stage, chatOverrideProviderId: chatOverrideProviderId)
        if let chatOverrideProviderId, !chatOverrideProviderId.rawValue.isEmpty {
            if let chatOverrideModelId, !chatOverrideModelId.rawValue.isEmpty { return chatOverrideModelId }
            return selectedModelId(forProvider: p.id)
        }
        return modelId(forStage: stage, fallbackProvider: p.id)
    }

    /// Resolves the effective provider and concrete cached model for a chat.
    /// A provider-only selection maps to the discovered default model, then the
    /// first advertised model, so catalog capability remains available when no
    /// explicit model override is stored.
    public func resolvedChatCatalogSelection(
        chatOverrideProviderID: ProviderID? = nil,
        chatOverrideModelID: ModelID? = nil
    ) -> (provider: AgentProvider, model: CachedModelInfo?) {
        let provider = provider(
            forStage: "chat", chatOverrideProviderId: chatOverrideProviderID)
        let models = cachedModels(forProvider: provider.id)
        let resolvedModelID = modelId(
            forStage: "chat",
            chatOverrideProviderId: chatOverrideProviderID,
            chatOverrideModelId: chatOverrideModelID)
        let model = resolvedModelID.flatMap { id in models.first { $0.modelId == id } }
            ?? models.first(where: \.isDefault)
            ?? models.first
        return (provider, model)
    }

    public func resolveThinkingCapability(
        providerID: ProviderID,
        modelID: ModelID?,
        configuredValueID: ChatConfigurationValueID? = nil,
        priorEffectiveValueID: ChatConfigurationValueID? = nil,
        liveCapability: ThinkingCapabilityCatalog? = nil,
        liveCurrentValueID: ChatConfigurationValueID? = nil,
        localOverride: ThinkingCapabilityCatalog? = nil
    ) -> ThinkingSelectionResolution {
        let models = cachedModels(forProvider: providerID)
        let selectedModel: CachedModelInfo?
        if let modelID {
            selectedModel = models.first { $0.modelId == modelID }
        } else {
            selectedModel = models.first(where: \.isDefault) ?? models.first
        }
        let observation = catalogObservation(forProvider: providerID)
            ?? legacyObservation(providerID: providerID, modelID: selectedModel?.modelId)
        let adapter = CodexThinkingCapabilityAdapter.resolve(
            fingerprint: observation?.fingerprint,
            selectedModelID: selectedModel?.modelId,
            models: observation?.models ?? models)
        let resolvedOverride = localOverride ?? LocalThinkingCapabilityRegistry.bundled.resolve(
            fingerprint: observation?.fingerprint,
            modelID: selectedModel?.modelId)
        return ThinkingCapabilityResolver.resolve(.init(
            selectedProviderID: providerID,
            selectedModelID: selectedModel?.modelId,
            liveACP: liveCapability,
            liveCurrentValueID: liveCurrentValueID,
            cachedObservation: observation,
            adapter: adapter,
            localOverride: resolvedOverride,
            configuredValueID: configuredValueID,
            priorEffectiveValueID: priorEffectiveValueID))
    }

    /// Resolves the normalized thinking capability for a chat through the one
    /// evidence-priority policy. SwiftUI and daemon code consume only this result.
    public func resolveThinkingCapability(
        chatOverrideProviderID: ProviderID? = nil,
        chatOverrideModelID: ModelID? = nil,
        configuredValueID: ChatConfigurationValueID? = nil,
        priorEffectiveValueID: ChatConfigurationValueID? = nil,
        liveCapability: ThinkingCapabilityCatalog? = nil,
        liveCurrentValueID: ChatConfigurationValueID? = nil,
        localOverride: ThinkingCapabilityCatalog? = nil
    ) -> ThinkingSelectionResolution {
        let selection = resolvedChatCatalogSelection(
            chatOverrideProviderID: chatOverrideProviderID,
            chatOverrideModelID: chatOverrideModelID)
        return resolveThinkingCapability(
            providerID: selection.provider.id,
            modelID: selection.model?.modelId,
            configuredValueID: configuredValueID,
            priorEffectiveValueID: priorEffectiveValueID,
            liveCapability: liveCapability,
            liveCurrentValueID: liveCurrentValueID,
            localOverride: localOverride)
    }

    private func legacyObservation(
        providerID: ProviderID,
        modelID: ModelID?
    ) -> ACPProviderCatalogObservation? {
        let models = cachedModels(forProvider: providerID)
        guard !models.isEmpty else { return nil }
        guard let selected = modelID.flatMap({ id in models.first { $0.modelId == id } })
            ?? models.first(where: \.isDefault)
            ?? models.first else { return nil }
        return ACPProviderCatalogObservation(
            providerID: providerID,
            fingerprint: nil,
            models: models,
            currentModelID: selected.modelId,
            thinkingCapability: selected.thinkingOptionCatalog.map {
                ThinkingCapabilityCatalog.observedACP($0)
            },
            observedAt: .distantPast)
    }

    /// The chat composer may enable submission only when the same resolved
    /// provider/model pair that the launcher validates is available. This keeps
    /// an all-disabled provider list or a missing selected model from reaching
    /// the daemon as a preflight failure.
    public func isChatOperationConfigured(
        chatOverrideProviderId: ProviderID? = nil,
        chatOverrideModelId: ModelID? = nil
    ) -> Bool {
        guard enabledProviders.isEmpty == false else { return false }
        let provider = provider(
            forStage: "chat",
            chatOverrideProviderId: chatOverrideProviderId
        )
        guard provider.enabled else { return false }
        guard let modelID = modelId(
            forStage: "chat",
            chatOverrideProviderId: chatOverrideProviderId,
            chatOverrideModelId: chatOverrideModelId
        ) else {
            return false
        }
        return modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // MARK: - Per-stage model selection (per-stage-model-selection plan)

    /// The model id to use for `stage` when the run resolves `providerId` as
    /// its one provider. Returns the stage's pinned model id when set +
    /// non-empty; otherwise falls back to the provider's `selectedModelId`
    /// (the #604 collapsed behavior — every stage shares one model). PURE so
    /// per-stage resolution is unit-tested without a subprocess.
    ///
    /// The run resolves ONE provider via `selectedProvider()`; per-stage only
    /// varies the model id within that provider's catalog. This matches the
    /// neuralwatt use case (`glm-5.2` / `glm-5.2-fast` / `glm-5.2-short` are
    /// one provider's variants) and keeps `providerHints` (spawn config)
    /// identical across phases — the warm subprocess is reused as-is.
    public func modelId(forStage stage: String, fallbackProvider providerId: ProviderID) -> ModelID? {
        if let id = ingestStageModelIds[stage], !id.rawValue.isEmpty { return id }
        return selectedModelId(forProvider: providerId)
    }

    /// A PURE mutator: returns a NEW config with the per-stage model id for
    /// `stage` set (or cleared when `modelId` is nil/empty/whitespace-only,
    /// restoring the "use the provider's `selectedModelId`" behavior). Called
    /// by the Settings UI's per-stage model picker; persisted by the launcher.
    /// Mirrors `settingSelectedModel(_:forProvider:)`'s carry-everything-else-
    /// through shape — a stage edit does NOT wipe other stages, the per-
    /// provider `selectedModelIds`, or any other field.
    public func settingIngestStageModel(_ modelId: ModelID?, forStage stage: String) -> AgentProvidersConfig {
        let normalized = (modelId?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : ModelID(rawValue: $0) }
        var stages = ingestStageModelIds
        if let normalized {
            stages[stage] = normalized
        } else {
            stages.removeValue(forKey: stage)
        }
        DebugLog.store("AgentProvidersConfig.settingIngestStageModel: stage=\(stage) modelId=\(normalized?.rawValue ?? "nil")")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: stages,
            stageProviderIds: stageProviderIds,
            catalogObservations: catalogObservations,
            generation: generation)
    }

    /// A PURE mutator: returns a NEW config with the per-stage PROVIDER pin for
    /// `stage` set (or cleared when `providerId` is nil/empty, restoring the
    /// "use the global default provider" behavior). Called by the Settings UI's
    /// per-stage provider picker; persisted by the view. Stale-model safety
    /// (agent-settings-tabs §2.2.3): when the provider pin CHANGES to a
    /// non-empty value, the stage's MODEL override (`ingestStageModelIds[stage]`)
    /// is CLEARED — a model id from the previous provider's catalog must never
    /// be sent to the new provider. The user then re-picks (or leaves "Same as
    /// provider"). Mirrors the carry-everything-else-through shape of the other
    /// setters.
    public func settingStageProvider(_ providerId: ProviderID?, forStage stage: String) -> AgentProvidersConfig {
        let normalized = (providerId?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : ProviderID(rawValue: $0) }
        var pins = stageProviderIds
        let didChange: Bool
        if let normalized {
            didChange = (pins[stage] != normalized)
            pins[stage] = normalized
        } else {
            didChange = (pins[stage] != nil)
            pins.removeValue(forKey: stage)
        }
        // Clear the stale model override when the provider pin changes, so a
        // model id from the old provider's catalog is never routed to the new
        // provider's subprocess.
        var stages = ingestStageModelIds
        if didChange {
            stages.removeValue(forKey: stage)
        }
        DebugLog.store("AgentProvidersConfig.settingStageProvider: stage=\(stage) providerId=\(normalized?.rawValue ?? "nil") clearedModel=\(didChange)")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: stages,
            stageProviderIds: pins,
            catalogObservations: catalogObservations,
            generation: generation)
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
    public func settingDefault(id: ProviderID) -> AgentProvidersConfig {
        var updated = providers
        for i in updated.indices {
            updated[i].isDefault = (updated[i].id == id)
        }
        // Carry over the per-provider model caches + selections + the
        // per-stage model overrides (don't wipe them when only the default
        // provider changes).
        return AgentProvidersConfig(
            providers: updated,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: ingestStageModelIds,
            stageProviderIds: stageProviderIds,
            catalogObservations: catalogObservations,
            generation: generation)
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
    public func cachedModels(forProvider providerId: ProviderID) -> [CachedModelInfo] {
        providerModels[providerId.rawValue] ?? []
    }

    public func catalogObservation(
        forProvider providerID: ProviderID
    ) -> ACPProviderCatalogObservation? {
        catalogObservations[providerID.rawValue]
    }

    /// Replaces a provider's models and complete successful observation in one
    /// value mutation. Empty discoveries are rejected by callers and therefore
    /// cannot erase the previous valid catalog.
    public func settingCatalogObservation(
        _ observation: ACPProviderCatalogObservation,
        forProvider providerID: ProviderID
    ) -> AgentProvidersConfig {
        precondition(observation.providerID == providerID)
        var modelCache = providerModels
        modelCache[providerID.rawValue] = observation.models
        var observations = catalogObservations
        observations[providerID.rawValue] = observation
        return AgentProvidersConfig(
            providers: providers,
            providerModels: modelCache,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: ingestStageModelIds,
            stageProviderIds: stageProviderIds,
            catalogObservations: observations,
            generation: generation)
    }

    /// The user's selected model id for `providerId`, or `nil` when none is set
    /// ("use the agent's default model"). PURE. Read by `ACPBackend.start` to
    /// decide whether to send `session/set_model`.
    public func selectedModelId(forProvider providerId: ProviderID) -> ModelID? {
        guard let id = selectedModelIds[providerId.rawValue], !id.rawValue.isEmpty else { return nil }
        return id
    }

    /// A PURE mutator: returns a NEW config with `providerId`'s cached models
    /// replaced by `models`. Called by the launcher after `backend.start`
    /// captures the agent's advertised `ModelsInfo`. The picker reads the result
    /// next load. Never writes secrets (only `CachedModelInfo`).
    public func settingCachedModels(_ models: [CachedModelInfo], forProvider providerId: ProviderID) -> AgentProvidersConfig {
        var cache = providerModels
        if models.isEmpty {
            cache.removeValue(forKey: providerId.rawValue)
        } else {
            cache[providerId.rawValue] = models
        }
        DebugLog.store("AgentProvidersConfig.settingCachedModels: provider=\(providerId.rawValue) count=\(models.isEmpty ? 0 : models.count)")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: cache,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: ingestStageModelIds,
            stageProviderIds: stageProviderIds,
            catalogObservations: catalogObservations,
            generation: generation)
    }

    /// A PURE mutator: returns a NEW config with the user's model selection for
    /// `providerId` set (or cleared when `modelId` is nil/empty). Called by the
    /// chat-composer model picker; persisted by the launcher. A nil/empty
    /// selection = "use the agent's default" → today's behavior is unchanged.
    public func settingSelectedModel(_ modelId: ModelID?, forProvider providerId: ProviderID) -> AgentProvidersConfig {
        var selections = selectedModelIds
        if let modelId, !modelId.rawValue.isEmpty {
            selections[providerId.rawValue] = modelId
        } else {
            selections.removeValue(forKey: providerId.rawValue)
        }
        DebugLog.store("AgentProvidersConfig.settingSelectedModel: provider=\(providerId.rawValue) modelId=\(modelId?.rawValue ?? "nil")")
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selections,
            favoriteModelIds: favoriteModelIds,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: ingestStageModelIds,
            stageProviderIds: stageProviderIds,
            catalogObservations: catalogObservations,
            generation: generation)
    }

    // MARK: - Favorites (#favorites — display-only, paseo per-row star)

    /// Whether `modelId` is favorited for `providerId`. PURE.
    public func isFavoriteModel(_ modelId: ModelID, forProvider providerId: ProviderID) -> Bool {
        favoriteModelIds[providerId.rawValue]?.contains(modelId) ?? false
    }

    /// The favorited model ids for `providerId`, in favorite order. PURE.
    public func favoriteModels(forProvider providerId: ProviderID) -> [ModelID] {
        favoriteModelIds[providerId.rawValue] ?? []
    }

    /// A PURE mutator: returns a NEW config with `modelId`'s favorite state
    /// toggled for `providerId`. Newly-favorited ids append (preserving order);
    /// removing the last favorite drops the provider key. Persisted by the
    /// launcher; the picker re-sorts favorites to the top on the next read.
    public func togglingFavoriteModel(_ modelId: ModelID, forProvider providerId: ProviderID) -> AgentProvidersConfig {
        var favorites = favoriteModelIds
        var list = favorites[providerId.rawValue] ?? []
        if let idx = list.firstIndex(of: modelId) {
            list.remove(at: idx)
        } else {
            list.append(modelId)
        }
        if list.isEmpty {
            favorites.removeValue(forKey: providerId.rawValue)
        } else {
            favorites[providerId.rawValue] = list
        }
        return AgentProvidersConfig(
            providers: providers,
            providerModels: providerModels,
            selectedModelIds: selectedModelIds,
            favoriteModelIds: favorites,
            maxConcurrent: maxConcurrent,
            ingestStageModelIds: ingestStageModelIds,
            stageProviderIds: stageProviderIds,
            catalogObservations: catalogObservations,
            generation: generation)
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
            selectedModelIds: ["claude-acp": ModelID(rawValue: "sonnet")])
    }

    // MARK: - Persistence

    /// Legacy direct writer retained only for bootstrap and tests. Production
    /// read-modify-write paths must use `AgentProvidersConfigStore.mutate(_:)`.
    func save(to directory: URL) throws {
        try writeAtomically(to: directory)
        NotificationCenter.default.post(
            name: .agentProvidersConfigDidChange,
            object: directory.standardizedFileURL
        )
    }

    /// Writes the JSON payload without emitting notifications. This is the store
    /// seam; application code must use `AgentProvidersConfigStore` instead.
    public func writeAtomically(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Load `agent-providers.json` from `directory`. If it is missing, empty,
    /// or corrupt, return the seed without writing during this read. The first
    /// logical mutation persists it through `AgentProvidersConfigStore` while
    /// holding the process and kernel locks.
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
            if config.providers.first(where: { $0.isDefault && $0.id == ProviderID(rawValue: "claude-acp") }) != nil,
               config.selectedModelId(forProvider: ProviderID(rawValue: "claude-acp")) == nil {
                DebugLog.store("AgentProvidersConfig.loadOrSeed: BACKFILL claude-acp default-model='sonnet'")
                selectedModelIds = selectedModelIds.merging(
                    ["claude-acp": ModelID(rawValue: "sonnet")],
                    uniquingKeysWith: { current, _ in current })
            }
            return AgentProvidersConfig(
                providers: config.providers,
                providerModels: config.providerModels,
                selectedModelIds: selectedModelIds,
                favoriteModelIds: config.favoriteModelIds,
                maxConcurrent: config.maxConcurrent,
                ingestStageModelIds: config.ingestStageModelIds,
                stageProviderIds: config.stageProviderIds,
                catalogObservations: config.catalogObservations,
                generation: config.generation)
        }
        // Missing, corrupt, or empty: return the seed without an unlocked write.
        DebugLog.store("AgentProvidersConfig.loadOrSeed: SEED (file missing/corrupt/empty; not persisted during read)")
        return seed(discovered: discover())
    }
}
