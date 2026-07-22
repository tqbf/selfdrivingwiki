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

    // MARK: - ACPModelSelectionResolver.resolveConfigOptionModel (#834)
    //
    // claude-acp advertises model selection as a "model" config option
    // (session/set_config_option), NOT via ModelsInfo.availableModels. These
    // cover the config-option decision path that applyModelIfNeeded tries FIRST
    // (returning nil → fall through to the setModel resolver above). Pure — no
    // subprocess. Mirrors the structure of the `resolve` tests above.

    /// Helper: build a "model" select config option with given values + current.
    private func modelConfigOption(current: String, values: [String]) -> SessionConfigOption {
        let options = values.map {
            SessionConfigSelectOption(value: SessionConfigValueId($0), name: $0)
        }
        return SessionConfigOption(
            id: SessionConfigId("model"),
            name: "Model",
            kind: .select(SessionConfigSelect(
                currentValue: SessionConfigValueId(current),
                options: .ungrouped(options))))
    }

    /// Helper: a non-model config option (e.g. thought_level) — for the
    /// "no model option" case.
    private func thoughtLevelConfigOption() -> SessionConfigOption {
        let options = ["high", "medium", "low"].map {
            SessionConfigSelectOption(value: SessionConfigValueId($0), name: $0)
        }
        return SessionConfigOption(
            id: SessionConfigId("thought_level"),
            name: "Thinking",
            kind: .select(SessionConfigSelect(
                currentValue: SessionConfigValueId("medium"),
                options: .ungrouped(options))))
    }

    /// Helper: a "model" select identified by CATEGORY (not id) — for the
    /// forward-compat id-OR-category match heuristic.
    private func modelConfigOptionByCategory(current: String, values: [String]) -> SessionConfigOption {
        let options = values.map {
            SessionConfigSelectOption(value: SessionConfigValueId($0), name: $0)
        }
        return SessionConfigOption(
            id: SessionConfigId("x"),
            name: "Model",
            category: "model",
            kind: .select(SessionConfigSelect(
                currentValue: SessionConfigValueId(current),
                options: .ungrouped(options))))
    }

    @Test func configOptionModel_appliesValidSelection() {
        // The bug scenario: claude-acp's pinned "haiku" is dropped because
        // availableModels is empty. The config-option path picks it up.
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "haiku",
            configOptions: [modelConfigOption(current: "sonnet", values: ["haiku", "sonnet", "opus"])])
        #expect(decision == .applyViaModelConfigOption(selectedValue: "haiku"))
    }

    @Test func configOptionModel_alreadyCurrentSkips() {
        // Selection matches the agent's current model → no-op round-trip.
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "sonnet",
            configOptions: [modelConfigOption(current: "sonnet", values: ["haiku", "sonnet", "opus"])])
        #expect(decision == .useAgentDefault)
    }

    @Test func configOptionModel_staleSelectionFallsBack() {
        // The user previously selected a model the agent no longer advertises.
        // Sending it would reproduce the rejection the picker exists to prevent.
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "removed",
            configOptions: [modelConfigOption(current: "haiku", values: ["haiku", "sonnet"])])
        #expect(decision == .useAgentDefault)
    }

    @Test func configOptionModel_noSelectionUsesDefault() {
        // No user selection → agent default (the select's currentValue).
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: nil,
            configOptions: [modelConfigOption(current: "sonnet", values: ["haiku", "sonnet"])])
        #expect(decision == .useAgentDefault)
    }

    @Test func configOptionModel_emptySelectionUsesDefault() {
        // Empty selection → agent default (same as nil).
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "",
            configOptions: [modelConfigOption(current: "sonnet", values: ["haiku", "sonnet"])])
        #expect(decision == .useAgentDefault)
    }

    @Test func configOptionModel_noModelOptionReturnsNil() {
        // The agent advertises config options, but none is "model" → nil (caller
        // falls through to the setModel path).
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "haiku",
            configOptions: [thoughtLevelConfigOption()])
        #expect(decision == nil)
    }

    @Test func configOptionModel_emptyConfigOptionsReturnsNil() {
        // No config options at all → nil (older agents → setModel path).
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "haiku",
            configOptions: [])
        #expect(decision == nil)
    }

    @Test func configOptionModel_categoryMatchWorks() {
        // An agent that identifies the model option by category (not id) — the
        // id-OR-category heuristic resolves it.
        let decision = ACPModelSelectionResolver.resolveConfigOptionModel(
            selectedModelId: "haiku",
            configOptions: [modelConfigOptionByCategory(current: "sonnet", values: ["haiku", "sonnet"])])
        #expect(decision == .applyViaModelConfigOption(selectedValue: "haiku"))
    }

    // MARK: - ACPModelSelectionResolver.configOptionValues (helper flatten)

    @Test func configOptionValues_flattensUngrouped() {
        let options = [
            SessionConfigSelectOption(value: SessionConfigValueId("haiku"), name: "Haiku"),
            SessionConfigSelectOption(value: SessionConfigValueId("sonnet"), name: "Sonnet"),
        ]
        let values = ACPModelSelectionResolver.configOptionValues(from: .ungrouped(options))
        #expect(values == ["haiku", "sonnet"])
    }

    @Test func configOptionValues_flattensGrouped() {
        let group1 = SessionConfigSelectGroup(
            group: SessionConfigGroupId("fast"),
            name: "Fast",
            options: [SessionConfigSelectOption(value: SessionConfigValueId("haiku"), name: "Haiku")])
        let group2 = SessionConfigSelectGroup(
            group: SessionConfigGroupId("smart"),
            name: "Smart",
            options: [SessionConfigSelectOption(value: SessionConfigValueId("sonnet"), name: "Sonnet")])
        let values = ACPModelSelectionResolver.configOptionValues(from: .grouped([group1, group2]))
        #expect(values == ["haiku", "sonnet"])
    }

    // MARK: - ACPModelSelectionResolver (setModel path unchanged by #834)

    @Test func setModelPathStillAppliesWhenNoConfigOption() {
        // Regression guard: when there's no "model" config option, the existing
        // setModel resolver + decision path is unchanged by #834. A valid
        // differing selection still resolves to .apply (setModel), NOT to the
        // new config-option case.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-4.7",
            currentModelId: "glm-4-7",
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
