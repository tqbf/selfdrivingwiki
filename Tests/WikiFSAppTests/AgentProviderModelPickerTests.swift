#if os(macOS)
import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import ACPModel
import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

/// #329 per-provider model picker tests. Pure logic only — NO live agent
/// subprocess (the slice forbids end-to-end testing; `ACPSmokeTests` covers the
/// Claude path). Covers:
///   1. `ACPModelSelectionResolver.resolve` — the selection→setModel decision
///      (no selection → default; stale selection → default; valid differing
///      selection → apply; already-current → default).
///   2. `AgentProvidersConfig` model cache + per-provider selection (set/get,
///      persistence round-trip with caches, forward-compat decode of pre-#329
///      files, cache not wiped on default switch).
///   3. `CachedModelInfo.displayLabel` (friendly name vs raw id fallback).
///   4. The `AgentBackendFactory.providerHints` `acpSelectedModelId` threading.
///   5. Picker selection persistence via `AgentLauncher.setSelectedModelAndDefault`
///      (model + default land atomically).
@Suite struct AgentProviderModelPickerTests {

    // MARK: - ACPModelSelectionResolver (pure selection→setModel decision)

    @Test func noSelectionUsesAgentDefault() {
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: nil,
            currentModelId: "glm-4-7",
            advertisedModelIds: ["glm-4-7", "glm-4.7"])
        #expect(decision == .useAgentDefault)
    }

    @Test func emptySelectionUsesAgentDefault() {
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "",
            currentModelId: "glm-4-7",
            advertisedModelIds: ["glm-4-7", "glm-4.7"])
        #expect(decision == .useAgentDefault)
    }

    @Test func validDifferingSelectionApplies() {
        // The bug scenario: agent ships bad default `glm-4-7`; user picks the
        // valid `glm-4.7` from the advertised list → setModel should fire.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-4.7",
            currentModelId: "glm-4-7",
            advertisedModelIds: ["glm-4-7", "glm-4.7"])
        #expect(decision == .apply(selectedId: "glm-4.7"))
    }

    @Test func alreadyCurrentSelectionSkipsSetModel() {
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-4.7",
            currentModelId: "glm-4.7",
            advertisedModelIds: ["glm-4-7", "glm-4.7"])
        #expect(decision == .useAgentDefault)
    }

    @Test func staleSelectionFallsBackToDefault() {
        // The user previously selected a model the agent no longer advertises.
        // Sending it would reproduce the 404 → fall back to the agent default.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "removed-model",
            currentModelId: "glm-4-7",
            advertisedModelIds: ["glm-4-7", "glm-4.7"])
        #expect(decision == .useAgentDefault)
    }

    @Test func noAdvertisedListUsesAgentDefault() {
        // Older agents that don't advertise a models list → never override.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-4.7",
            currentModelId: nil,
            advertisedModelIds: [])
        #expect(decision == .useAgentDefault)
    }

    @Test func nilCurrentButAdvertisedStillApplies() {
        // Agent advertises a list but no explicit currentModelId → a valid
        // selection still applies (we can't claim it's already current).
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-4.7",
            currentModelId: nil,
            advertisedModelIds: ["glm-4-7", "glm-4.7"])
        #expect(decision == .apply(selectedId: "glm-4.7"))
    }

    // MARK: - CachedModelInfo

    @Test func displayLabelUsesFriendlyNameWhenPresent() {
        let model = CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7", description: nil)
        #expect(model.displayLabel == "GLM-4.7")
    }

    @Test func displayLabelFallsBackToModelId() {
        // A bad-default model like `glm-4-7` is still recognizable via its raw id.
        let model = CachedModelInfo(modelId: "glm-4-7", name: "", description: nil)
        #expect(model.displayLabel == "glm-4-7")
    }

    // MARK: - AgentProvidersConfig model cache + selection

    @Test func cacheAndSelectionRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-models-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let models = [
            CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7"),
            CachedModelInfo(modelId: "glm-4-7", name: "GLM 4.7 (broken default)"),
        ]
        let original = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude", label: "Claude", enabled: true, isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
            ],
            providerModels: ["hermes": models],
            selectedModelIds: ["hermes": "glm-4.7"])
        try original.save(to: tmp)

        let url = tmp.appendingPathComponent(AgentProvidersConfig.fileName, isDirectory: false)
        let loaded = try JSONDecoder().decode(AgentProvidersConfig.self, from: Data(contentsOf: url))
        #expect(loaded.cachedModels(forProvider: "hermes").map(\.modelId) == ["glm-4.7", "glm-4-7"])
        #expect(loaded.selectedModelId(forProvider: "hermes") == "glm-4.7")
        // Phase 1: the claudeCachedModels injection is removed — Claude has no
        // cached models until ACP discovery captures a real list.
        #expect(loaded.cachedModels(forProvider: "claude-acp").isEmpty)
        #expect(loaded.cachedModels(forProvider: "claude").isEmpty)
        // No selection for either Claude provider → nil (agent default).
        #expect(loaded.selectedModelId(forProvider: "claude-acp") == nil)
        #expect(loaded.selectedModelId(forProvider: "claude") == nil)
    }

    @Test func preModelCacheFileDecodesWithEmptyCaches() throws {
        // A pre-#329 agent-providers.json (no providerModels / selectedModelIds
        // keys) must decode without a migration → empty caches (legacy
        // behavior: "no model selected → agent default"). Phase 1 removes the
        // claudeCachedModels injection, so no cached models are synthesized
        // — a real list only appears after ACP discovery.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let legacyJSON = """
        {
          "providers": [
            {"id":"claude","label":"Claude","backend":"claudeCLI","command":null,"env":{},"enabled":true,"isDefault":true}
          ]
        }
        """
        let url = tmp.appendingPathComponent(AgentProvidersConfig.fileName, isDirectory: false)
        try legacyJSON.data(using: .utf8)!.write(to: url)

        let loaded = try JSONDecoder().decode(AgentProvidersConfig.self, from: Data(contentsOf: url))
        // No hardcoded injection — Claude has no cached models yet.
        #expect(loaded.cachedModels(forProvider: "claude-acp").isEmpty)
        #expect(loaded.cachedModels(forProvider: "claude").isEmpty)
        // Selections remain empty (legacy: no model selected → agent default).
        #expect(loaded.selectedModelIds.isEmpty)
        #expect(loaded.selectedModelId(forProvider: "claude") == nil)
        // No claude-acp force-insertion: the decoded provider list is exactly
        // what the legacy file specified.
        #expect(loaded.providers.map(\.id) == ["claude"])
    }

    @Test func settingCachedModelsReplacesAndPersists() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes"], isDefault: true),
        ])
        let models = [CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7")]
        let updated = config.settingCachedModels(models, forProvider: "hermes")
        #expect(updated.cachedModels(forProvider: "hermes").count == 1)
        #expect(updated.cachedModels(forProvider: "hermes").first?.modelId == "glm-4.7")
        // Original is unchanged (value semantics).
        #expect(config.cachedModels(forProvider: "hermes") == [])
    }

    @Test func settingCachedModelsEmptyClearsEntry() {
        let config = AgentProvidersConfig(
            providers: [AgentProvider(id: "hermes", label: "Hermes", command: ["hermes"], isDefault: true)],
            providerModels: ["hermes": [CachedModelInfo(modelId: "x", name: "X")]])
        let updated = config.settingCachedModels([], forProvider: "hermes")
        #expect(updated.cachedModels(forProvider: "hermes") == [])
        #expect(updated.providerModels["hermes"] == nil)
    }

    @Test func settingSelectedModelAndClearing() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes"], isDefault: true),
        ])
        let selected = config.settingSelectedModel("glm-4.7", forProvider: "hermes")
        #expect(selected.selectedModelId(forProvider: "hermes") == "glm-4.7")
        let cleared = selected.settingSelectedModel(nil, forProvider: "hermes")
        #expect(cleared.selectedModelId(forProvider: "hermes") == nil)
        // Empty string also clears.
        let reselected = cleared.settingSelectedModel("", forProvider: "hermes")
        #expect(reselected.selectedModelId(forProvider: "hermes") == nil)
    }

    @Test func switchingDefaultProviderPreservesModelCaches() {
        // The picker sets the default provider when picking a model; that path
        // must NOT wipe the per-provider model caches or selections.
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "claude", label: "Claude", isDefault: true),
                AgentProvider(id: "hermes", label: "Hermes", command: ["hermes"], isDefault: false),
            ],
            providerModels: ["hermes": [CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7")]],
            selectedModelIds: ["hermes": "glm-4.7"])
        let switched = config.settingDefault(id: "hermes")
        #expect(switched.defaultProvider.id == "hermes")
        #expect(switched.cachedModels(forProvider: "hermes").map(\.modelId) == ["glm-4.7"])
        #expect(switched.selectedModelId(forProvider: "hermes") == "glm-4.7")
    }

    // MARK: - providerHints selectedModelId threading

    @Test func providerHintsCarriesSelectedModelId() {
        let provider = AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/hermes", "acp"],
            apiKey: "secret",
            selectedModelId: "glm-4.7")
        #expect(hints[HintKey.acpSelectedModelId.rawValue] == "glm-4.7")
        #expect(hints[HintKey.acpAgentPath.rawValue] == "/usr/local/bin/hermes")
    }

    @Test func providerHintsOmitsSelectedModelIdWhenNil() {
        let provider = AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"])
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: ["/usr/local/bin/hermes", "acp"],
            apiKey: nil,
            selectedModelId: nil)
        #expect(hints[HintKey.acpSelectedModelId.rawValue] == nil)
    }

    @Test func providerHintsEmptyWhenCommandUnresolved() {
        // Phase 4 (ACP-only): an empty resolved command yields empty hints —
        // even with a model selection — so ACPBackend throws noAgentConfigured
        // instead of spawning garbage.
        let provider = AgentProvider(id: "claude-acp", label: "Claude")
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: [],
            apiKey: nil,
            selectedModelId: "sonnet")
        #expect(hints.isEmpty)
    }

    // MARK: - Picker selection persistence (launcher atomic set)

    @MainActor
    @Test func setSelectedModelAndDefaultIsAtomic() throws {
        // The picker's "pick a model" path: choosing a model implies choosing
        // its provider, and both land in ONE load→mutate→save cycle (no race).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("picker-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let initial = AgentProvidersConfig(providers: [
            AgentProvider(id: "claude", label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
        ])
        try initial.save(to: tmp)

        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }

        let hermes = initial.provider(id: "hermes")!
        _ = launcher.setSelectedModelAndDefault("glm-4.7", provider: hermes)

        let reloaded = AgentProvidersConfig.loadOrSeed(from: tmp)
        #expect(reloaded.defaultProvider.id == "hermes")
        #expect(reloaded.selectedModelId(forProvider: "hermes") == "glm-4.7")
        // Claude's selection is untouched.
        #expect(reloaded.selectedModelId(forProvider: "claude") == nil)
    }
}

/// Model-capture simulation: exercises the cache seam WITHOUT a live agent.
/// Mirrors how the launcher maps the SDK's `ModelInfo` → `CachedModelInfo` and
/// persists per-provider. The launcher's `cacheDiscoveredModels` does the same
/// `map` after `backend.availableModels(for:)`; here we drive it directly with
/// a synthetic `[ModelInfo]` (the SDK type returned by `newSession`).
@Suite struct AgentProviderModelCaptureTests {

    @MainActor
    @Test func captureMapsSDKModelInfoToCache() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Simulate the SDK's ModelsInfo.availableModels (the agent's own list).
        let discovered: [ModelInfo] = [
            ModelInfo(modelId: "glm-4.7", name: "GLM-4.7", description: "Fast"),
            ModelInfo(modelId: "glm-4-7", name: "GLM 4.7", description: "Legacy default"),
        ]
        // The launcher's cache path maps SDK → CachedModelInfo + persists.
        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }
        let provider = AgentProvider(id: "hermes", label: "Hermes", command: ["hermes"], isDefault: true)
        try AgentProvidersConfig(providers: [provider]).save(to: tmp)

        let cached = discovered.map {
            CachedModelInfo(modelId: $0.modelId, name: $0.name, description: $0.description)
        }
        launcher.cacheDiscoveredModels(cached, forProvider: "hermes")

        let reloaded = AgentProvidersConfig.loadOrSeed(from: tmp)
        #expect(reloaded.cachedModels(forProvider: "hermes").map(\.modelId) == ["glm-4.7", "glm-4-7"])
        #expect(reloaded.cachedModels(forProvider: "hermes").first?.name == "GLM-4.7")
    }

    @MainActor
    @Test func captureIgnoresEmptyModelList() {
        // An agent that advertised nothing (older agent) must not write an
        // empty cache entry that would shadow the picker's hint.
        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("capture-empty-\(UUID().uuidString)", isDirectory: true)
        }
        launcher.cacheDiscoveredModels([], forProvider: "hermes")
        // No crash, no throw — empty is a guarded no-op in cacheDiscoveredModels.
        #expect(launcher.providersConfig().cachedModels(forProvider: "hermes") == [])
    }
}
#endif
