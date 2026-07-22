#if os(macOS)
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

    @Test func seedYieldsClaudeAcpDefaultOnly() {
        // #663: seed() emits a single provider — Claude ACP — as the default.
        // (The Hermes/OpenCode seed statics were removed; first-run
        // discoverability now flows through the `AddProviderSheet` +
        // `ACPProviderCatalog` suggestions surface.)
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.providers.map(\.id) == ["claude-acp"])
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
        // The seed always yields the single Claude default — discovered agents
        // are ignored (the user opts in via Settings → Add Provider).
        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/usr/local/bin/gemini"),
            DiscoveredACPAgent(agent: KnownACPAgent(id: "hermes", label: "Hermes", summary: "", detectExecutable: "hermes", command: ["hermes", "acp"]), resolvedPath: "/usr/local/bin/hermes"),
        ]
        let config = AgentProvidersConfig.seed(discovered: discovered)
        #expect(config.providers.map(\.id) == ["claude-acp"])
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

    @Test func normalizedReseedsClaudeAcpOnlyWhenEmpty() {
        // #663: providers.isEmpty re-seeds `[claudeAcpDefault]` (the three-
        // default seed was removed; the catalog-driven `AddProviderSheet`
        // replaced it for first-run discoverability).
        let config = AgentProvidersConfig(providers: [])
        #expect(config.providers.map(\.id) == ["claude-acp"])
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

    // MARK: - AC.3 (#663): hermes/opencode IDs round-trip after static removal

    /// After #663 (deletion of `.hermesDefault`/`.opencodeDefault`), the
    /// `AgentProvider` type itself is unchanged — only the static SEED
    /// constants were deleted. A user's existing `agent-providers.json`
    /// containing hermes/opencode rows MUST still decode + re-encode
    /// losslessly. No migration needed (the IDs are no longer special —
    /// they're just user-configured providers whose id happens to match
    /// a catalog entry).
    @Test func hermesOpencodeIDsRoundTripAfterStaticRemoval() throws {
        let original = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"], enabled: true, isDefault: true),
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], env: ["ZAI_API_KEY": "x"], enabled: true, isDefault: false),
            AgentProvider(id: "opencode", label: "OpenCode", command: ["opencode", "acp"], enabled: false, isDefault: false),
        ])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentProvidersConfig.self, from: encoded)
        #expect(decoded == original)
        // Pin the per-provider fields that previously lived on the deleted
        // statics — same id, same command, same env.
        #expect(decoded.provider(id: "hermes")?.command == ["hermes", "acp"])
        #expect(decoded.provider(id: "hermes")?.env == ["ZAI_API_KEY": "x"])
        #expect(decoded.provider(id: "opencode")?.command == ["opencode", "acp"])
        // Default's still claude-acp.
        #expect(decoded.defaultProvider.id == "claude-acp")
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

    @Test func loadOrSeedSeedsTheSingleClaudeDefaultIgnoringDiscovery() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-disc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let discovered = [
            DiscoveredACPAgent(agent: KnownACPAgent(id: "gemini", label: "Gemini CLI", summary: "", detectExecutable: "gemini", command: ["gemini", "--acp"]), resolvedPath: "/x"),
        ]
        let config = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { discovered })
        // #663: Discovered agents are ignored — the single Claude default is seeded.
        #expect(config.providers.map(\.id) == ["claude-acp"])
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

    @Test func selectedModelIdIsNilWhenNothingConfigured() {
        // Reproduce the diagnosed-bug precondition: the resolved provider has
        // no `selectedModelIds` entry, so its `selectedModelId(forProvider:)`
        // returns nil. The launcher's `SpawnModelGuard` keys on exactly this
        // state to refuse spawn — this test pins the precondition so the guard
        // has a stable contract.
        //
        // The state: opencode is the default provider (the user manually set
        // `isDefault = true` — constructed inline because #663 deleted the
        // `.opencodeDefault` static alongside the Hermes/OpenCode seeds; the
        // catalog-driven `AddProviderSheet` replaced them) AND has no
        // `selectedModelIds` entry → `selectedModelId(forProvider:)` returns
        // nil. (#604 removed the per-stage assignment API; this is the same
        // precondition the collapsed single-resolution path uses.)
        var opencodeAsDefault = AgentProvider(
            id: "opencode",
            label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:],
            enabled: true,
            isDefault: false)
        opencodeAsDefault.isDefault = true
        let config = AgentProvidersConfig(providers: [opencodeAsDefault])
        let provider = config.selectedProvider()
        let modelId = config.selectedModelId(forProvider: provider.id)
        #expect(provider.id == "opencode")
        #expect(modelId == nil)
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
/// and the legacy `stageAssignments` JSON key ignored on decode (#604 removed
/// per-stage routing; the key is silently dropped). Pure logic only — no live
/// agent subprocess.
@Suite struct AgentProvidersConfigPhase1Tests {

    // MARK: - Old-JSON decode compatibility

    /// A legacy `agent-providers.json` that contains a stale `stageAssignments`
    /// key (#604 removed the field; the key is no longer in `CodingKeys`)
    /// MUST decode without error — `JSONDecoder` silently ignores unknown
    /// keys. The stale data is dropped; providers + selections are intact.
    @Test func legacyJSONWithStagesKeyDecodesAndIgnoresIt() throws {
        let legacyJSON = """
        {
          "providers": [
            {"id":"claude-acp","label":"Claude","backend":"acp","command":["bun","x","@agentclientprotocol/claude-agent-acp"],"env":{},"enabled":true,"isDefault":true},
            {"id":"hermes","label":"Hermes","backend":"acp","command":["hermes","acp"],"env":{"ZAI_API_KEY":"x"},"enabled":true,"isDefault":false}
          ],
          "providerModels": {},
          "selectedModelIds": {},
          "favoriteModelIds": {},
          "stageAssignments": {"planner": {"providerId": "hermes", "modelId": "x"}}
        }
        """
        let loaded = try JSONDecoder().decode(AgentProvidersConfig.self, from: legacyJSON.data(using: .utf8)!)
        #expect(loaded.providers.map(\.id) == ["claude-acp", "hermes"])
        #expect(loaded.provider(id: "hermes")?.env == ["ZAI_API_KEY": "x"])
        // The stages key was silently dropped — there is no `stageAssignments`
        // property anymore. The default provider resolves normally.
        #expect(loaded.selectedProvider().id == "claude-acp")
    }

    // MARK: - Empty-list reseed

    @Test func emptyProvidersListReseedsClaudeAcpOnly() {
        // #663: empty providers list re-seeds `[claudeAcpDefault]` only (the
        // Hermes/OpenCode seeds were removed in favour of the catalog-driven
        // `AddProviderSheet`).
        let config = AgentProvidersConfig(providers: [])
        #expect(config.providers.map(\.id) == ["claude-acp"])
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

    // MARK: - #604: all ingest stages resolve to the app default provider

    /// After #604, per-stage routing is gone: the launcher resolves ONE
    /// (provider, modelId) pair via `selectedProvider()` + `selectedModelId`,
    /// and all three phases (planner/executor/finalizer) share it. Pin that
    /// this pair is what the (removed) per-stage resolution would have
    /// returned, so a future re-add of per-stage routing doesn't silently
    /// bypass the default.
    @Test func ingestStagesResolveToAppDefaultProvider() {
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
            ],
            selectedModelIds: ["claude-acp": "sonnet"])
        let provider = config.selectedProvider()
        let modelId = config.selectedModelId(forProvider: provider.id)
        #expect(provider.id == "claude-acp")
        #expect(modelId == "sonnet")
        // The planner/executor/finalizer no longer have a distinct API;
        // they all use this single resolution.
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
        #expect(msg?.contains("Settings → Providers") == true)
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
        #expect(msg?.contains("Settings → Providers") == true)
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
#endif
