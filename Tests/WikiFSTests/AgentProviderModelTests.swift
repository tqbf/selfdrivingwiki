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

    @Test func seedAlwaysLeadsWithClaudeDefault() {
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.providers.first?.id == "claude")
        #expect(config.providers.first?.backend == .claudeCLI)
        #expect(config.providers.first?.isDefault == true)
        #expect(config.providers.first?.enabled == true)
    }

    @Test func seedInjectsClaudeHardcodedModels() {
        // Claude has no ACP model discovery, so its model list is the hardcoded
        // alias set (opus/sonnet/haiku) — seeded so the picker has rows.
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.cachedModels(forProvider: "claude").map(\.modelId) == ["opus", "sonnet", "haiku"])
        // Discovered ACP agents have no cached models yet (discovered on first chat).
        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "hermes", label: "Hermes", summary: "", detectExecutable: "hermes", command: ["hermes", "acp"]), resolvedPath: "/x"),
        ]
        let seeded = AgentProvidersConfig.seed(discovered: discovered)
        #expect(seeded.cachedModels(forProvider: "hermes") == [])
        #expect(seeded.cachedModels(forProvider: "claude").map(\.modelId) == ["opus", "sonnet", "haiku"])
    }

    @Test func seedAppendsDiscoveredACPAgentsNotDefault() {
        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/usr/local/bin/gemini"),
            DiscoveredACPAgent(agent: KnownACPAgent(id: "hermes", label: "Hermes", summary: "", detectExecutable: "hermes", command: ["hermes", "acp"]), resolvedPath: "/usr/local/bin/hermes"),
        ]
        let config = AgentProvidersConfig.seed(discovered: discovered)
        #expect(config.providers.count == 3) // Claude + gemini + hermes
        let acp = config.providers.filter { $0.backend == .acp }
        #expect(acp.map(\.id).sorted() == ["gemini", "hermes"])
        // Discovered ACP providers are enabled but NOT default.
        #expect(acp.allSatisfy { !$0.isDefault })
        #expect(acp.allSatisfy { $0.enabled })
        // Their command carries over from the catalog agent.
        #expect(acp.first(where: { $0.id == "gemini" })?.command == ["gemini", "--acp"])
    }

    @Test func seedDedupsDiscoveredById() {
        let agent = KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"])
        let discovered = [
            DiscoveredACPAgent(agent: agent, resolvedPath: "/a/gemini"),
            DiscoveredACPAgent(agent: agent, resolvedPath: "/b/gemini"),
        ]
        let config = AgentProvidersConfig.seed(discovered: discovered)
        #expect(config.providers.filter { $0.id == "gemini" }.count == 1)
    }

    @Test func seedNeverDuplicatesClaude() {
        // A discovered agent named "claude" must not collide with the built-in.
        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "claude", label: "Fake Claude", summary: "", detectExecutable: "claude", command: ["claude"]), resolvedPath: "/x"),
        ]
        let config = AgentProvidersConfig.seed(discovered: discovered)
        #expect(config.providers.filter { $0.id == "claude" }.count == 1)
        #expect(config.providers.first?.backend == .claudeCLI) // the built-in, not a dup
    }

    // MARK: - Normalization (single-default invariant)

    @Test func normalizedEnforcesSingleDefault() {
        let raw = [
            AgentProvider(id: "a", label: "A", backend: .acp, command: ["a"], isDefault: true),
            AgentProvider(id: "b", label: "B", backend: .acp, command: ["b"], isDefault: true),
        ]
        let config = AgentProvidersConfig(providers: raw)
        // Claude is prepended (its `claudeDefault` has isDefault == true) and is
        // the FIRST default encountered → exactly one default, and it's Claude.
        let defaults = config.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(config.defaultProvider.id == "claude")
        // The user-provided defaults were demoted.
        #expect(config.providers.first(where: { $0.id == "a" })?.isDefault == false)
        #expect(config.providers.first(where: { $0.id == "b" })?.isDefault == false)
    }

    @Test func normalizedMakesClaudeDefaultWhenNone() {
        let raw = [
            AgentProvider(id: "a", label: "A", backend: .acp, command: ["a"], isDefault: false),
        ]
        let config = AgentProvidersConfig(providers: raw)
        #expect(config.defaultProvider.id == "claude")
    }

    // MARK: - Selection

    @Test func selectedProviderPicksDefaultWhenEnabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "claude")
    }

    @Test func selectedProviderFallsBackToFirstEnabled() {
        // Default (Claude) disabled → falls back to the first enabled provider.
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: false, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "gemini")
    }

    @Test func selectedProviderFallsBackToClaudeWhenAllDisabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: false, isDefault: true),
            AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"], enabled: false, isDefault: false),
        ])
        #expect(config.selectedProvider().id == "claude")
    }

    // MARK: - Persistence round-trip

    @Test func persistenceRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", backend: .claudeCLI, enabled: true, isDefault: true),
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
        #expect(config.providers.first?.id == "claude")
        // The seed is persisted so the next load is stable.
        let url = tmp.appendingPathComponent(AgentProvidersConfig.fileName, isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func loadOrSeedUsesDiscovered() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-disc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/x"),
        ]
        let config = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { discovered })
        #expect(config.providers.contains(where: { $0.id == "gemini" }))
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
        // Claude (ACP wrapper) is deliberately NOT in the catalog — Claude is
        // driven directly via ClaudeCLIBackend (claude -p), not over ACP.
        #expect(!ids.contains("claude-agent-acp"))
        // codex-acp (npx wrapper) removed — the catalog is node-free (direct binaries only).
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
        let backend = AgentBackendFactory.makeBackend(provider: provider, policy: .yolo)
        #expect(backend is ClaudeCLIBackend)
        // CLI backend has no permission channel.
        #expect(!(backend is PermissionResolving))
    }

    @Test func acpProviderYieldsACPBackend() {
        let provider = AgentProvider(id: "gemini", label: "Gemini", backend: .acp, command: ["gemini", "--acp"])
        let backend = AgentBackendFactory.makeBackend(provider: provider, policy: .yolo)
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
