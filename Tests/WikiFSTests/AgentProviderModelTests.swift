import Testing
import Foundation
import ACPModel
@testable import WikiFS
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

    @Test func seedAlwaysLeadsWithClaudeAcpDefault() {
        let config = AgentProvidersConfig.seed(discovered: [])
        // Only claude-acp is seeded — the sole supported provider.
        #expect(config.providers.count == 1)
        #expect(config.providers.first?.id == "claude-acp")
        #expect(config.providers.first?.backend == .acp)
        #expect(config.providers.first?.isDefault == true)
        #expect(config.providers.first?.enabled == true)
    }

    @Test func seedInjectsClaudeHardcodedModels() {
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.cachedModels(forProvider: "claude-acp").map(\.modelId) == ["opus", "sonnet", "haiku"])
    }

    @Test func seedIgnoresDiscoveredAgents() {
        // The seed only includes claude-acp — discovered agents are ignored.
        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/usr/local/bin/gemini"),
            DiscoveredACPAgent(agent: KnownACPAgent(id: "hermes", label: "Hermes", summary: "", detectExecutable: "hermes", command: ["hermes", "acp"]), resolvedPath: "/usr/local/bin/hermes"),
        ]
        let config = AgentProvidersConfig.seed(discovered: discovered)
        #expect(config.providers.count == 1)
        #expect(config.providers.first?.id == "claude-acp")
    }

    // MARK: - Normalization (single-default invariant)

    @Test func normalizedEnforcesSingleDefault() {
        let raw = [
            AgentProvider(id: "a", label: "A", backend: .acp, command: ["a"], isDefault: true),
            AgentProvider(id: "b", label: "B", backend: .acp, command: ["b"], isDefault: true),
        ]
        let config = AgentProvidersConfig(providers: raw)
        // claude-acp is prepended (its `claudeAcpDefault` has isDefault == true)
        // and is the FIRST default encountered → exactly one default, claude-acp.
        let defaults = config.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(config.defaultProvider.id == "claude-acp")
        // The user-provided defaults were demoted.
        #expect(config.providers.first(where: { $0.id == "a" })?.isDefault == false)
        #expect(config.providers.first(where: { $0.id == "b" })?.isDefault == false)
    }

    @Test func normalizedMakesClaudeAcpDefaultWhenNone() {
        let raw = [
            AgentProvider(id: "a", label: "A", backend: .acp, command: ["a"], isDefault: false),
        ]
        let config = AgentProvidersConfig(providers: raw)
        #expect(config.defaultProvider.id == "claude-acp")
    }

    // MARK: - Selection

    @Test func selectedProviderPicksDefaultWhenEnabled() {
        // normalized() injects claude-acp as the enabled default; selectedProvider()
        // returns it.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "claude-acp")
    }

    @Test func selectedProviderFallsBackToFirstEnabled() {
        // Default (claude-acp) disabled → falls back to the first enabled provider.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", backend: .acp, command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: false, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "gemini")
    }

    @Test func selectedProviderFallsBackToClaudeAcpWhenAllDisabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", backend: .acp, command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: false, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: false, isDefault: false),
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
            AgentProvider(id: "claude-acp", label: "Claude", backend: .acp, command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: true, isDefault: true),
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: false),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], env: ["FOO": "bar"], enabled: true, isDefault: false),
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

    @Test func loadOrSeedSeedsOnlyClaudeAcp() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-disc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/x"),
        ]
        let config = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { discovered })
        // Only claude-acp is seeded — discovered agents are ignored.
        #expect(config.providers.count == 1)
        #expect(config.providers.first?.id == "claude-acp")
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

    @Test func claudeCLIProviderYieldsClaudeBackend() {
        let provider = AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI)
        let backend = AgentBackendFactory.makeBackend(provider: provider, policy: .bypass)
        #expect(backend is ClaudeCLIBackend)
        // CLI backend has no permission channel.
        #expect(!(backend is PermissionResolving))
    }

    @Test func acpProviderYieldsACPBackend() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"])
        let backend = AgentBackendFactory.makeBackend(provider: provider, policy: .bypass)
        #expect(backend is ACPBackend)
        #expect(backend is PermissionResolving)
    }

    @Test func acpProviderThreadsAlwaysAskPolicy() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"])
        let backend = AgentBackendFactory.makeBackend(provider: provider, policy: .alwaysAsk)
        #expect(backend is ACPBackend)
    }

    // MARK: - providerHints

    @Test func providerHintsForACPProvider() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/gemini", "--acp"],
            apiKey: "secret")
        #expect(hints["acpAgentPath"] == "/usr/local/bin/gemini")
        #expect(hints["acpAgentArgs"] == "--acp")
        #expect(hints["acpAgentApiKey"] == "secret")
    }

    @Test func providerHintsEmptyForCLIProvider() {
        let provider = AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI)
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: [],
            apiKey: nil)
        #expect(hints.isEmpty)
    }

    @Test func providerHintsEmptyForACPWithNoCommand() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: nil)
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: [],
            apiKey: nil)
        #expect(hints.isEmpty)
    }

    @Test func providerHintsNoApiKeyWhenAbsent() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/gemini", "--acp"],
            apiKey: nil)
        #expect(hints["acpAgentApiKey"] == nil)
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
        #expect(provider.backend == .acp)
        #expect(provider.command == ["gemini", "--acp"])
        #expect(provider.isDefault == false)
    }
}
