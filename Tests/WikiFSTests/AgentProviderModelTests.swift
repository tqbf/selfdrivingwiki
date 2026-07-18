import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import ACPModel
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// #324 provider model + selection tests. Pure logic only — NO live agent
/// subprocess (the slice forbids end-to-end testing). Covers:
/// - `AgentProvidersConfig`: seed (Claude default + discovered ACP), persistence
///   round-trip, default selection + normalization.
/// - Catalog: expanded entries present; Claude absent; command[0]==detectExecutable.
/// - Selection→backend mapping: claudeCLI→ClaudeCLIBackend; acp→ACPBackend with
///   the provider's command+key.
@Suite struct AgentProviderModelTests {

    // MARK: - Seed

    @Test func seedYieldsAllThreeDefaultProvidersWithClaudeDefault() {
        // Phase 1: seed() emits the three seed providers — Claude, Hermes,
        // OpenCode — with Claude as the default.
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.providers.map(\.id) == ["claude-acp", "hermes", "opencode"])
        #expect(config.providers.first?.isDefault == true)
        #expect(config.providers.allSatisfy { $0.enabled })
        #expect(config.providers.filter(\.isDefault).count == 1)
    }

    @Test func seedNoLongerInjectsClaudeHardcodedModels() {
        // Phase 1: the claudeCachedModels injection is removed — model lists
        // come from ACP discovery (providerModels), not a hardcoded alias list.
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.cachedModels(forProvider: "claude-acp").isEmpty)
    }

    @Test func seedIgnoresDiscoveredAgents() {
        // The seed always yields the three fixed defaults — discovered agents
        // are ignored (the user opts in via Settings).
        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/usr/local/bin/gemini"),
            DiscoveredACPAgent(agent: KnownACPAgent(id: "hermes", label: "Hermes", summary: "", detectExecutable: "hermes", command: ["hermes", "acp"]), resolvedPath: "/usr/local/bin/hermes"),
        ]
        let config = AgentProvidersConfig.seed(discovered: discovered)
        #expect(config.providers.map(\.id) == ["claude-acp", "hermes", "opencode"])
    }

    // MARK: - Normalization (single-default invariant)

    @Test func normalizedEnforcesSingleDefault() {
        // Phase 1: no force-inserted claude-acp — the FIRST isDefault==true
        // provider in the input list keeps it, the rest are demoted.
        let raw = [
            AgentProvider(id: "a", label: "A", command: ["a"], isDefault: true),
            AgentProvider(id: "b", label: "B", command: ["b"], isDefault: true),
        ]
        let config = AgentProvidersConfig(providers: raw)
        let defaults = config.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(config.defaultProvider.id == "a")
        // The second default was demoted.
        #expect(config.providers.first(where: { $0.id == "b" })?.isDefault == false)
    }

    @Test func normalizedPromotesFirstEnabledWhenNoneDefault() {
        // Phase 1: with none marked default, the FIRST ENABLED provider is
        // promoted (no more hardcoded claude-acp fallback).
        let raw = [
            AgentProvider(id: "a", label: "A", command: ["a"], enabled: false, isDefault: false),
            AgentProvider(id: "b", label: "B", command: ["b"], enabled: true, isDefault: false),
        ]
        let config = AgentProvidersConfig(providers: raw)
        #expect(config.defaultProvider.id == "b")
    }

    @Test func normalizedReseedsAllThreeWhenEmpty() {
        // Phase 1: providers.isEmpty re-seeds all three defaults (Claude
        // default).
        let config = AgentProvidersConfig(providers: [])
        #expect(config.providers.map(\.id) == ["claude-acp", "hermes", "opencode"])
        #expect(config.defaultProvider.id == "claude-acp")
    }

    // MARK: - Selection

    @Test func selectedProviderPicksDefaultWhenEnabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "claude")
    }

    @Test func selectedProviderFallsBackToFirstEnabled() {
        // Default (claude-acp) disabled → falls back to the first enabled provider.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: false, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "gemini")
    }

    @Test func selectedProviderFallsBackToClaudeAcpWhenAllDisabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: false, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], enabled: false, isDefault: false),
        ])
        // All disabled → falls back to the claudeAcpDefault static.
        #expect(config.selectedProvider().id == "claude-acp")
    }

    // MARK: - Persistence round-trip

    @Test func persistenceRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Include claude-acp explicitly so the raw providers list matches the
        // normalized list (normalized() would otherwise prepend it). This keeps
        // the model-cache injection symmetric between init(providers:) and
        // init(from:) → the round-trip is exactly equal.
        let original = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: true, isDefault: true),
            AgentProvider(id: "claude", label: "Claude", enabled: true, isDefault: false),
            AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"], env: ["FOO": "bar"], enabled: true, isDefault: false),
        ])
        try original.save(to: tmp)

        let url = tmp.appendingPathComponent(AgentProvidersConfig.fileName, isDirectory: false)
        let data = try Data(contentsOf: url)
        let loaded = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        #expect(loaded == original)
        #expect(loaded.provider(id: "gemini")?.command == ["gemini", "--acp"])
        #expect(loaded.provider(id: "gemini")?.env == ["FOO": "bar"])
    }

    @Test func loadOrSeedSeedsWhenMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(config.providers.first?.id == "claude-acp")
        // The seed is persisted so the next load is stable.
        let url = tmp.appendingPathComponent(AgentProvidersConfig.fileName, isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func loadOrSeedSeedsTheThreeDefaultsIgnoringDiscovery() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-disc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/x"),
        ]
        let config = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { discovered })
        // Discovered agents are ignored — the three fixed defaults are seeded.
        #expect(config.providers.map(\.id) == ["claude-acp", "hermes", "opencode"])
    }

    // MARK: - Favorites (display-only per-row star)

    @Test func togglingFavoriteAddsThenRemoves() {
        let config = AgentProvidersConfig(providers: [.claudeAcpDefault])
        #expect(!config.isFavoriteModel("opus", forProvider: "claude-acp"))

        let favorited = config.togglingFavoriteModel("opus", forProvider: "claude-acp")
        #expect(favorited.isFavoriteModel("opus", forProvider: "claude-acp"))
        #expect(favorited.favoriteModels(forProvider: "claude-acp") == ["opus"])

        // Toggling again clears it (and drops the now-empty provider key).
        let cleared = favorited.togglingFavoriteModel("opus", forProvider: "claude-acp")
        #expect(!cleared.isFavoriteModel("opus", forProvider: "claude-acp"))
        #expect(cleared.favoriteModelIds["claude-acp"] == nil)
    }

    @Test func favoritesArePerProviderAndOrdered() {
        let config = AgentProvidersConfig(providers: [.claudeAcpDefault])
            .togglingFavoriteModel("opus", forProvider: "claude-acp")
            .togglingFavoriteModel("haiku", forProvider: "claude-acp")
            .togglingFavoriteModel("gpt", forProvider: "other")
        // Insertion order is preserved; providers are isolated.
        #expect(config.favoriteModels(forProvider: "claude-acp") == ["opus", "haiku"])
        #expect(config.favoriteModels(forProvider: "other") == ["gpt"])
        #expect(!config.isFavoriteModel("opus", forProvider: "other"))
    }

    @Test func favoritesSurviveSelectionAndDefaultRewraps() {
        // Favorites must be threaded through the other setting* mutators, not
        // wiped when the selection or default provider changes.
        let config = AgentProvidersConfig(providers: [.claudeAcpDefault])
            .togglingFavoriteModel("opus", forProvider: "claude-acp")
            .settingSelectedModel("sonnet", forProvider: "claude-acp")
            .settingDefault(id: "claude-acp")
        #expect(config.isFavoriteModel("opus", forProvider: "claude-acp"))
        #expect(config.selectedModelId(forProvider: "claude-acp") == "sonnet")
    }

    @Test func favoritesRoundTripThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-fav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = AgentProvidersConfig(providers: [.claudeAcpDefault])
            .togglingFavoriteModel("opus", forProvider: "claude-acp")
        try original.save(to: tmp)

        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(loaded.isFavoriteModel("opus", forProvider: "claude-acp"))
    }

    // MARK: - SpawnModelGuard precondition (diagnosed 2026-07-18 bug state)

    @Test func resolvedProviderReturnsNilModelWhenNothingConfigured() {
        // Reproduce the diagnosed-bug precondition: the resolved provider has
        // no `selectedModelIds` entry, so `resolvedProvider(for:)` returns a
        // nil `modelId`. The launcher's `SpawnModelGuard` keys on exactly this
        // state to refuse spawn — this test pins the precondition so the guard
        // has a stable contract.
        //
        // The state: opencode is the default provider (the user manually set
        // `isDefault = true` — note `.opencodeDefault` ships with
        // `isDefault: false`, so we override) AND has no `selectedModelIds`
        // entry. `resolvedProvider(for:)` falls back to `selectedProvider()`
        // (the stage assignment is empty) → returns `(opencode, nil)`.
        var opencodeAsDefault = AgentProvider.opencodeDefault
        opencodeAsDefault.isDefault = true
        let config = AgentProvidersConfig(providers: [opencodeAsDefault])
        let resolved = config.resolvedProvider(for: .planner)
        #expect(resolved.provider.id == "opencode")
        #expect(resolved.modelId == nil)
        // This is the exact state `SpawnModelGuard.validate` refuses to spawn on
        // — confirmed by `SpawnModelGuardTests.returnsErrorMessageWhenModelIdIsNil`.
    }
}

@Suite struct AgentProviderCatalogTests {

    @Test func catalogHasExpandedEntries() {
        let ids = Set(ACPProviderCatalog.agents.map(\.id))
        #expect(ids.contains("gemini"))
        #expect(ids.contains("hermes"))
        #expect(ids.contains("copilot"))
        #expect(ids.contains("kimi"))
        #expect(ids.contains("cursor"))
        #expect(ids.contains("kiro"))
        // Claude via the official ACP wrapper IS in the catalog (the default chat
        // provider); the legacy `claude -p` CLI id is NOT (driven via ClaudeCLIBackend).
        #expect(ids.contains("claude-acp"))
        #expect(!ids.contains("claude"))
        // codex-acp (npx wrapper) removed — the catalog is npx-free.
        #expect(!ids.contains("codex-acp"))
    }

    @Test func claudeIsAbsent() {
        #expect(!ACPProviderCatalog.agents.contains(where: { $0.id == "claude" }))
    }

    @Test func commandFirstEqualsDetectExecutable() {
        for agent in ACPProviderCatalog.agents {
            #expect(agent.command.first == agent.detectExecutable)
        }
    }

    @Test func npxWrappersDetectNpx() {
        for agent in ACPProviderCatalog.agents where agent.command.first == "npx" {
            #expect(agent.detectExecutable == "npx")
        }
    }
}

@Suite struct AgentProviderSelectionTests {

    // MARK: - Selection → backend mapping

    @Test func acpProviderYieldsACPBackend() {
        // Phase 4 (acp-multi-provider): the factory is ACP-only.
        let backend = AgentBackendFactory.makeBackend(policy: .bypass)
        #expect(backend is ACPBackend)
        #expect(backend is PermissionResolving)
    }

    @Test func acpProviderThreadsAlwaysAskPolicy() {
        let backend = AgentBackendFactory.makeBackend(policy: .alwaysAsk)
        #expect(backend is ACPBackend)
    }

    // MARK: - providerHints

    @Test func providerHintsForACPProvider() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/gemini", "--acp"],
            apiKey: "secret")
        #expect(hints[HintKey.acpAgentPath.rawValue] == "/usr/local/bin/gemini")
        #expect(hints[HintKey.acpAgentArgs.rawValue] == "--acp")
        #expect(hints[HintKey.acpAgentApiKey.rawValue] == "secret")
    }

    @Test func providerHintsEmptyForCLIProvider() {
        let provider = AgentProvider(id: "claude", label: "Claude")
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: [],
            apiKey: nil)
        #expect(hints.isEmpty)
    }

    @Test func providerHintsEmptyForACPWithNoCommand() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", command: nil)
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: [],
            apiKey: nil)
        #expect(hints.isEmpty)
    }

    @Test func providerHintsNoApiKeyWhenAbsent() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", command: ["gemini", "--acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/gemini", "--acp"],
            apiKey: nil)
        #expect(hints[HintKey.acpAgentApiKey.rawValue] == nil)
    }
}

@Suite struct ACPCredentialStorePerProviderTests {

    @Test func perProviderKeysAreIsolated() throws {
        let store = InMemoryACPCredentialStore()
        try store.setAPIKey("gemini-key", forProvider: "gemini")
        try store.setAPIKey("hermes-key", forProvider: "hermes")
        #expect(store.apiKey(forProvider: "gemini") == "gemini-key")
        #expect(store.apiKey(forProvider: "hermes") == "hermes-key")
        // Independent slots.
        try store.setAPIKey(nil, forProvider: "gemini")
        #expect(store.apiKey(forProvider: "gemini") == nil)
        #expect(store.apiKey(forProvider: "hermes") == "hermes-key")
    }

    @Test func legacySingleKeyIndependentOfPerProvider() throws {
        let store = InMemoryACPCredentialStore()
        try store.setAPIKey("legacy")
        try store.setAPIKey("provider-key", forProvider: "gemini")
        #expect(store.apiKey() == "legacy")
        #expect(store.apiKey(forProvider: "gemini") == "provider-key")
    }

    @Test func acpFromCatalogAgentCarriesCommand() {
        let agent = KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"])
        let provider = AgentProvider.acp(from: agent)
        #expect(provider.id == "gemini")
        #expect(provider.command == ["gemini", "--acp"])
        #expect(provider.isDefault == false)
    }
}

/// Phase 1 (acp-multi-provider) tests: old-JSON decode compatibility,
/// empty-list reseed, default promotion when the default provider is deleted,
/// and `IngestStage`/`StageAssignment` resolution + fallback + pruning. Pure
/// logic only — no live agent subprocess.
@Suite struct AgentProvidersConfigPhase1Tests {

    // MARK: - Old-JSON decode compatibility

    /// A pre-Phase-1 `agent-providers.json` (has `env`/`enabled` but no
    /// `stageAssignments` key) must decode without a migration.
    @Test func oldJSONWithoutStageAssignmentsDecodes() throws {
        let legacyJSON = """
        {
          "providers": [
            {"id":"claude-acp","label":"Claude","backend":"acp","command":["bun","x","@agentclientprotocol/claude-agent-acp"],"env":{},"enabled":true,"isDefault":true},
            {"id":"hermes","label":"Hermes","backend":"acp","command":["hermes","acp"],"env":{"ZAI_API_KEY":"x"},"enabled":true,"isDefault":false}
          ],
          "providerModels": {},
          "selectedModelIds": {},
          "favoriteModelIds": {}
        }
        """
        let loaded = try JSONDecoder().decode(AgentProvidersConfig.self, from: legacyJSON.data(using: .utf8)!)
        #expect(loaded.providers.map(\.id) == ["claude-acp", "hermes"])
        #expect(loaded.provider(id: "hermes")?.env == ["ZAI_API_KEY": "x"])
        #expect(loaded.stageAssignments.isEmpty)
        // Every stage falls back to selectedProvider() with no assignment.
        #expect(loaded.resolvedProvider(for: .planner).provider.id == "claude-acp")
    }

    // MARK: - Empty-list reseed

    @Test func emptyProvidersListReseedsAllThreeDefaults() {
        let config = AgentProvidersConfig(providers: [])
        #expect(config.providers.map(\.id) == ["claude-acp", "hermes", "opencode"])
        #expect(config.defaultProvider.id == "claude-acp")
        #expect(config.providers.filter(\.isDefault).count == 1)
    }

    // MARK: - Default promotion when the default provider is deleted

    @Test func defaultPromotionWhenDefaultProviderDeleted() {
        // Start with hermes as default, then simulate deletion by rebuilding
        // the config without it — the first remaining ENABLED provider is
        // promoted.
        let withHermesDefault = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: false),
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: true),
        ])
        #expect(withHermesDefault.defaultProvider.id == "hermes")

        let afterDeletingHermes = AgentProvidersConfig(providers: withHermesDefault.providers.filter { $0.id != "hermes" })
        #expect(afterDeletingHermes.defaultProvider.id == "claude-acp")
        #expect(afterDeletingHermes.providers.filter(\.isDefault).count == 1)
    }

    @Test func defaultPromotionSkipsDisabledProviders() {
        // No provider marked default, and the first in list order is disabled
        // → the first ENABLED provider is promoted, not the first overall.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "a", label: "A", command: ["a"], enabled: false, isDefault: false),
            AgentProvider(id: "b", label: "B", command: ["b"], enabled: true, isDefault: false),
        ])
        #expect(config.defaultProvider.id == "b")
    }

    // MARK: - Stage assignment resolution + fallback + pruning

    @Test func resolvedProviderUsesStageAssignment() {
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
            ],
            stageAssignments: [.planner: StageAssignment(providerId: "hermes", modelId: "glm-4.7")])
        let resolved = config.resolvedProvider(for: .planner)
        #expect(resolved.provider.id == "hermes")
        #expect(resolved.modelId == "glm-4.7")
    }

    @Test func resolvedProviderFallsBackToSelectedModelIdWhenAssignmentHasNoModel() {
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
            ],
            selectedModelIds: ["hermes": "glm-4.7"],
            stageAssignments: [.executor: StageAssignment(providerId: "hermes", modelId: nil)])
        let resolved = config.resolvedProvider(for: .executor)
        #expect(resolved.provider.id == "hermes")
        #expect(resolved.modelId == "glm-4.7")
    }

    @Test func resolvedProviderFallsBackToSelectedProviderWhenStageUnassigned() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
        ])
        // .finalizer has no assignment at all.
        let resolved = config.resolvedProvider(for: .finalizer)
        #expect(resolved.provider.id == "claude-acp")
    }

    @Test func stageAssignmentPrunedWhenProviderDeleted() {
        // Build with an assignment, then rebuild without that provider — the
        // constructor prunes the now-dangling assignment.
        let withAssignment = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
            ],
            stageAssignments: [.planner: StageAssignment(providerId: "hermes")])
        #expect(withAssignment.stageAssignments[.planner] != nil)

        let afterDeletingHermes = AgentProvidersConfig(
            providers: withAssignment.providers.filter { $0.id != "hermes" },
            stageAssignments: withAssignment.stageAssignments)
        #expect(afterDeletingHermes.stageAssignments[.planner] == nil)
        // Falls back to selectedProvider() now that the assignment is pruned.
        #expect(afterDeletingHermes.resolvedProvider(for: .planner).provider.id == "claude-acp")
    }

    @Test func stageAssignmentPrunedWhenProviderDisabled() {
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: false, isDefault: false),
            ],
            stageAssignments: [.executor: StageAssignment(providerId: "hermes")])
        // hermes is disabled → the assignment is pruned at construction time.
        #expect(config.stageAssignments[.executor] == nil)
        #expect(config.resolvedProvider(for: .executor).provider.id == "claude-acp")
    }

    // MARK: - Claude no longer force-inserted

    @Test func claudeIsNoLongerForceInsertedIntoAnArbitraryProviderList() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: true),
        ])
        #expect(config.providers.map(\.id) == ["hermes"])
        #expect(config.defaultProvider.id == "hermes")
    }

    @Test func claudeModelsAreNotAutoInjected() {
        // Phase 4: the hardcoded opus/sonnet/haiku alias list is gone — model
        // lists come only from ACP discovery (providerModels capture).
        let config = AgentProvidersConfig(providers: [.claudeAcpDefault])
        #expect(config.cachedModels(forProvider: "claude-acp").isEmpty)
    }

    // MARK: - Readiness (#440)

    @Test func readinessMessageReturnsNilWhenCommandResolves() {
        // The default Claude provider's `bun` command resolves via the
        // injected closure → nil (ready). We inject a stub that always
        // finds the binary so we don't depend on the real filesystem.
        let msg = AgentLauncher.readinessMessage(
            for: .claudeAcpDefault,
            resolveCommand: { _ in ["/usr/local/bin/bun"] })
        #expect(msg == nil)
    }

    @Test func readinessMessageReturnsMessageWhenBinaryNotFound() {
        // Inject a resolver that always fails → the provider is not ready.
        let provider = AgentProvider(
            id: "hermes", label: "Hermes",
            command: ["hermes", "acp"], enabled: true, isDefault: true)
        let msg = AgentLauncher.readinessMessage(
            for: provider,
            resolveCommand: { _ in nil })
        #expect(msg != nil)
        #expect(msg?.contains("was not found on your PATH") == true)
        #expect(msg?.contains("Settings → Agents") == true)
    }

    @Test func readinessMessageReturnsMessageWhenNoCommandConfigured() {
        // A provider with no command at all.
        let provider = AgentProvider(
            id: "broken", label: "Broken",
            command: nil, enabled: true, isDefault: true)
        let msg = AgentLauncher.readinessMessage(
            for: provider,
            resolveCommand: { _ in nil })
        #expect(msg != nil)
        #expect(msg?.contains("has no command configured") == true)
        #expect(msg?.contains("Settings → Agents") == true)
    }

    @Test func readinessMessageMentionsBunForBunProvider() {
        // The default Claude provider uses `bun` — the message should mention
        // bun.sh when the binary isn't found.
        let msg = AgentLauncher.readinessMessage(
            for: .claudeAcpDefault,
            resolveCommand: { _ in nil })
        #expect(msg != nil)
        #expect(msg?.contains("bun") == true)
        #expect(msg?.contains("bun.sh") == true)
    }
}
