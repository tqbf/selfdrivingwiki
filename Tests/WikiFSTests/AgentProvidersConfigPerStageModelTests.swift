import Testing
import Foundation
@testable import WikiFSCore

/// per-stage-model-selection plan §7: pure-logic tests for the per-stage model
/// overrides (`ingestStageModelIds` + `modelId(forStage:fallbackProvider:)` +
/// `settingIngestStageModel(_:forStage:)`). Mirrors the deleted per-op test
/// shape (`AgentProvidersConfigPerOpProviderTests`). NO subprocess — pure
/// config + resolver seam tests only.
///
/// Per-stage selection builds ON TOP of the per-provider `selectedModelId`
/// infrastructure (it stays — #704's per-op PROVIDER pin was removed, but the
/// per-provider model map remains). Per-stage only varies the model id within
/// ONE provider's catalog (e.g. `glm-5.2` / `glm-5.2-fast` / `glm-5.2-short`
/// — same provider's variants). See `plans/per-stage-model-selection.md`.
@Suite("AgentProvidersConfig per-stage model selection")
struct AgentProvidersConfigPerStageModelTests {

    // MARK: - Fixture

    /// One provider with three advertised model variants (matches the
    /// neuralwatt use case from the plan: same provider, model-level variants).
    private var fixture: AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: "neuralwatt", label: "Neuralwatt",
                    command: ["neuralwatt", "acp"], env: [:],
                    enabled: true, isDefault: true),
            ],
            providerModels: [
                "neuralwatt": [
                    CachedModelInfo(modelId: "glm-5.2", name: "GLM-5.2", description: nil),
                    CachedModelInfo(modelId: "glm-5.2-flex", name: "GLM-5.2 Flex", description: nil),
                    CachedModelInfo(modelId: "glm-5.2-short", name: "GLM-5.2 Short", description: nil),
                ]
            ],
            selectedModelIds: ["neuralwatt": "glm-5.2"])
    }

    // MARK: - ACPIngestStage

    @Test func stageEnumHasThreeCasesInOrder() {
        #expect(ACPIngestStage.allCases == [.planner, .executor, .finalizer])
    }

    @Test func stageLabelsAreCapitalized() {
        #expect(ACPIngestStage.planner.label == "Planner")
        #expect(ACPIngestStage.executor.label == "Executor")
        #expect(ACPIngestStage.finalizer.label == "Finalizer")
    }

    @Test func stageRawValuesMatchConfigKeys() {
        // The config keys are `"planner"`, `"executor"`, `"finalizer"` — these
        // MUST match `ACPIngestStage.rawValue` so the orchestrator and config
        // can never drift (the enum exists precisely for this compile-time check).
        #expect(ACPIngestStage.planner.rawValue == "planner")
        #expect(ACPIngestStage.executor.rawValue == "executor")
        #expect(ACPIngestStage.finalizer.rawValue == "finalizer")
    }

    // MARK: - Resolution: falls back to selectedModelId when stage unset

    @Test func modelForStageFallsBackToSelectedModelIdWhenUnset() {
        let config = fixture
        // No `ingestStageModelIds` entry → every stage falls back to the
        // provider's selectedModelId ("glm-5.2"). This is the #604 collapsed
        // behavior — every stage uses one model. Pin the contract.
        #expect(config.ingestStageModelIds.isEmpty)
        #expect(config.modelId(forStage: "planner", fallbackProvider: "neuralwatt") == "glm-5.2")
        #expect(config.modelId(forStage: "executor", fallbackProvider: "neuralwatt") == "glm-5.2")
        #expect(config.modelId(forStage: "finalizer", fallbackProvider: "neuralwatt") == "glm-5.2")
    }

    @Test func modelForStageFallsBackWhenProviderHasNoSelectedModelId() {
        // A provider with no `selectedModelIds` entry has no fallback → returns
        // nil (the agent's default model will be used). Mirrors the legacy
        // "no per-stage selection → use the agent's default" behavior.
        let config = AgentProvidersConfig(
            providers: [AgentProvider(id: "p", label: "P", command: ["p"], enabled: true, isDefault: true)])
        #expect(config.modelId(forStage: "planner", fallbackProvider: "p") == nil)
        #expect(config.modelId(forStage: "executor", fallbackProvider: "p") == nil)
    }

    // MARK: - Resolution: per-stage override wins

    @Test func modelForStageReturnsOverrideWhenSet() {
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingIngestStageModel("glm-5.2-short", forStage: "finalizer")
        #expect(config.modelId(forStage: "planner", fallbackProvider: "neuralwatt") == "glm-5.2")
        #expect(config.modelId(forStage: "executor", fallbackProvider: "neuralwatt") == "glm-5.2-flex")
        #expect(config.modelId(forStage: "finalizer", fallbackProvider: "neuralwatt") == "glm-5.2-short")
    }

    @Test func modelForStageIgnoresEmptyOverride() {
        // An empty string falls through to the fallback (matches
        // `selectedModelId(forProvider:)`'s empty collapse).
        let config = fixture.settingIngestStageModel("", forStage: "executor")
        #expect(config.modelId(forStage: "executor", fallbackProvider: "neuralwatt") == "glm-5.2")
        #expect(config.ingestStageModelIds["executor"] == nil)  // empty was normalized away
    }

    // MARK: - Setter: round-trip + nil/whitespace normalization

    @Test func settingIngestStageModelClearsOnNil() {
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingIngestStageModel(nil, forStage: "executor")
        #expect(config.ingestStageModelIds["executor"] == nil)
        #expect(config.modelId(forStage: "executor", fallbackProvider: "neuralwatt") == "glm-5.2")
    }

    @Test func settingIngestStageModelClearsOnEmpty() {
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingIngestStageModel("", forStage: "executor")
        #expect(config.ingestStageModelIds["executor"] == nil)
    }

    @Test func settingIngestStageModelTrimsWhitespace() {
        let config = fixture.settingIngestStageModel("  glm-5.2-flex  ", forStage: "executor")
        #expect(config.ingestStageModelIds["executor"] == "glm-5.2-flex")
    }

    @Test func settingIngestStageModelClearsOnWhitespaceOnly() {
        let config = fixture.settingIngestStageModel("   ", forStage: "executor")
        #expect(config.ingestStageModelIds["executor"] == nil)
    }

    @Test func stagesAreIndependent() {
        // Three stages, three different models — the core use case.
        let config = fixture
            .settingIngestStageModel("glm-5.2", forStage: "planner")
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingIngestStageModel("glm-5.2-short", forStage: "finalizer")
        #expect(config.modelId(forStage: "planner", fallbackProvider: "neuralwatt") == "glm-5.2")
        #expect(config.modelId(forStage: "executor", fallbackProvider: "neuralwatt") == "glm-5.2-flex")
        #expect(config.modelId(forStage: "finalizer", fallbackProvider: "neuralwatt") == "glm-5.2-short")
    }

    // MARK: - Carry-through: other setters preserve ingestStageModelIds

    @Test func settingDefaultPreservesIngestStageModels() {
        // Changing the default provider does NOT wipe the per-stage overrides.
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingDefault(id: "neuralwatt")
        #expect(config.ingestStageModelIds["executor"] == "glm-5.2-flex")
    }

    @Test func settingSelectedModelPreservesIngestStageModels() {
        // Changing the per-provider `selectedModelId` does NOT wipe the per-stage
        // overrides — they're independent fields.
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingSelectedModel("glm-5.2-short", forProvider: "neuralwatt")
        #expect(config.ingestStageModelIds["executor"] == "glm-5.2-flex")
        #expect(config.selectedModelId(forProvider: "neuralwatt") == "glm-5.2-short")
    }

    @Test func settingCachedModelsPreservesIngestStageModels() {
        let cached = [CachedModelInfo(modelId: "opus", name: "Opus", description: nil)]
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingCachedModels(cached, forProvider: "neuralwatt")
        #expect(config.ingestStageModelIds["executor"] == "glm-5.2-flex")
        #expect(config.cachedModels(forProvider: "neuralwatt").count == 1)
    }

    @Test func togglingFavoritePreservesIngestStageModels() {
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .togglingFavoriteModel("glm-5.2", forProvider: "neuralwatt")
        #expect(config.ingestStageModelIds["executor"] == "glm-5.2-flex")
        #expect(config.isFavoriteModel("glm-5.2", forProvider: "neuralwatt"))
    }

    // MARK: - Carry-through: settingIngestStageModel preserves other fields

    @Test func settingIngestStageModelPreservesSelectedModelIds() {
        let config = fixture
            .settingSelectedModel("glm-5.2", forProvider: "neuralwatt")
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
        #expect(config.selectedModelId(forProvider: "neuralwatt") == "glm-5.2")
    }

    @Test func settingIngestStageModelPreservesProviderModels() {
        let config = fixture
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
        #expect(config.cachedModels(forProvider: "neuralwatt").count == 3)
    }

    // MARK: - Codable backward-compat

    @Test func oldConfigWithoutIngestStageModelIdsDecodesToEmpty() throws {
        // A pre-per-stage `agent-providers.json` (no `ingestStageModelIds` key)
        // decodes to `[:]` → every stage uses the provider's `selectedModelId`
        // (the #604 collapsed behavior — no migration, no behavior change).
        let json = """
        {
          "providers": [
            { "id": "claude-acp", "label": "Claude", "command": ["bun", "x", "@agentclientprotocol/claude-agent-acp"], "env": {}, "enabled": true, "isDefault": true }
          ],
          "providerModels": {},
          "selectedModelIds": { "claude-acp": "sonnet" },
          "favoriteModelIds": {},
          "maxConcurrent": {}
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        #expect(config.ingestStageModelIds == [:])
        #expect(config.modelId(forStage: "planner", fallbackProvider: "claude-acp") == "sonnet")
        #expect(config.modelId(forStage: "executor", fallbackProvider: "claude-acp") == "sonnet")
        #expect(config.modelId(forStage: "finalizer", fallbackProvider: "claude-acp") == "sonnet")
    }

    @Test func ingestStageModelIdsRoundTripThroughDisk() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-stage-rt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = fixture
            .settingIngestStageModel("glm-5.2", forStage: "planner")
            .settingIngestStageModel("glm-5.2-flex", forStage: "executor")
            .settingIngestStageModel("glm-5.2-short", forStage: "finalizer")
        try original.save(to: tmp)

        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(loaded.ingestStageModelIds["planner"] == "glm-5.2")
        #expect(loaded.ingestStageModelIds["executor"] == "glm-5.2-flex")
        #expect(loaded.ingestStageModelIds["finalizer"] == "glm-5.2-short")
    }

    @Test func loadOrSeedPreservesIngestStageModelsFromDisk() throws {
        // loadOrSeed re-wraps the decoded config (re-applies normalization + the
        // claude-acp model backfill). That re-wrap must NOT wipe the per-stage
        // overrides — same carry-through contract as the per-op fields used.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-providers-stage-loadorseed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let original = AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: "claude-acp", label: "Claude",
                    command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
                    env: [:], enabled: true, isDefault: true),
            ],
            selectedModelIds: ["claude-acp": "sonnet"],
            ingestStageModelIds: ["executor": "haiku"])
        try original.save(to: tmp)

        let loaded = AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] })
        #expect(loaded.ingestStageModelIds["executor"] == "haiku")
        // Resolution-time fallback:
        #expect(loaded.modelId(forStage: "planner", fallbackProvider: "claude-acp") == "sonnet")
        #expect(loaded.modelId(forStage: "executor", fallbackProvider: "claude-acp") == "haiku")
    }

    // MARK: - Removed #704 fields are silently ignored

    @Test func oldConfigWithRemovedPerOpFieldsDecodesAndIgnoresThem() throws {
        // A live `agent-providers.json` that still has `chatProviderId` /
        // `ingestProviderId` / `lintProviderId` keys from the removed #704
        // per-op provider pin layer MUST decode without error — those keys are
        // silently ignored (not in `CodingKeys` anymore). Migration is silent
        // + automatic on the next save.
        let json = """
        {
          "providers": [
            { "id": "claude-acp", "label": "Claude", "command": ["bun"], "env": {}, "enabled": true, "isDefault": true }
          ],
          "providerModels": {},
          "selectedModelIds": { "claude-acp": "sonnet" },
          "favoriteModelIds": {},
          "maxConcurrent": {},
          "chatProviderId": "claude-acp",
          "ingestProviderId": "deleted-id",
          "lintProviderId": null
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        #expect(config.providers.count == 1)
        #expect(config.selectedProvider().id == "claude-acp")
    }
}

/// per-stage-model-selection plan §7: pure-logic tests for the
/// `ACPModelSelectionResolver.resolve` decision under per-stage inputs.
/// Proves the DECISION logic that drives `ACPBackend.applyModelIfNeeded`
/// without an actor or subprocess (the SDK `Client` is a concrete actor, NOT
/// a protocol — `ACPTurnRecoveryTests.swift:21-30` documents exactly this
/// gap; the integration is manual validation MV-1/MV-2/MV-3 only).
@Suite("ACPModelSelectionResolver per-stage decision")
struct ACPModelSelectionResolverPerStageTests {

    // MARK: - (a) executor selected ≠ baseline → .apply

    @Test func executorModelDifferentFromBaselineApplies() {
        // The fork path: baseline = planner's RESOLVED model (NOT the stale
        // stored modelsInfo.currentModelId — HIGH #2). Executor selected is a
        // different advertised model → resolver returns `.apply` → setModel
        // runs in `applyModelIfNeeded`.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-5.2-flex",
            currentModelId: "glm-5.2",  // the planner's RESOLVED model
            advertisedModelIds: ["glm-5.2", "glm-5.2-flex", "glm-5.2-short"])
        #expect(decision == .apply(selectedId: "glm-5.2-flex"))
    }

    // MARK: - (b) executor selected == baseline (the planner's resolved model) → no-op

    @Test func executorModelEqualsBaselineIsNoOp() {
        // MV-2 from the plan: with executor and planner set to the same model,
        // the forked executor's `applyModelIfNeeded` correctly no-ops (no
        // setModel round-trip). The baseline is the planner's RESOLVED model
        // — when executor == planner, the resolver's "already current → no-op"
        // guard fires correctly WITH an accurate baseline.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-5.2",
            currentModelId: "glm-5.2",  // planner == executor → no-op baseline match
            advertisedModelIds: ["glm-5.2", "glm-5.2-flex"])
        #expect(decision == .useAgentDefault)
    }

    // MARK: - (c) stale/unadvertised stage model → useAgentDefault (no 404)

    @Test func unadvertisedStageModelFallsBack() {
        // The user pinned an executor stage model that the agent no longer
        // advertises (stale selection). The resolver falls back to
        // `useAgentDefault` rather than reproducing the exact 404 the picker
        // exists to prevent. No setModel is sent.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "legacy-glm-4",
            currentModelId: "glm-5.2",
            advertisedModelIds: ["glm-5.2", "glm-5.2-flex"])
        #expect(decision == .useAgentDefault)
    }

    // MARK: - HIGH #2 regression: planner ≠ advertised default

    @Test func highRisk2PlannerNotDefaultExecutorIsDefaultStillApplies() {
        // MV-3: the regression case the plan calls out explicitly. The planner
        // is set to a non-default model; the executor is pinned to the
        // advertised default. With the STALE stored `currentModelId` (= the
        // advertised default), the resolver's "already current → no-op" guard
        // would WRONGLY no-op — the executor would silently stay on the
        // inherited PLANNER model (silent model bleed — the exact bug being
        // fixed).
        //
        // The fix: `applyModelIfNeeded` takes an EXPLICIT
        // `baselineCurrentModelId` (the planner's RESOLVED model, NOT the
        // stale stored id). The resolver then sees executor ≠ baseline →
        // `.apply` → setModel runs. This is the **core** HIGH #2 assertion.
        let plannerResolvedModel = "glm-5.2"
        let advertisedDefault = "glm-5.2-default"  // (only used by the stale path)
        let executorSelected = advertisedDefault
        // STALE path (the bug): baseline == advertised default → no-op.
        let staleDecision = ACPModelSelectionResolver.resolve(
            selectedModelId: executorSelected,
            currentModelId: advertisedDefault,
            advertisedModelIds: [advertisedDefault, plannerResolvedModel])
        #expect(staleDecision == .useAgentDefault)  // ← the bug
        // FIXED path: baseline == planner's RESOLVED model → .apply.
        let fixedDecision = ACPModelSelectionResolver.resolve(
            selectedModelId: executorSelected,
            currentModelId: plannerResolvedModel,
            advertisedModelIds: [advertisedDefault, plannerResolvedModel])
        #expect(fixedDecision == .apply(selectedId: executorSelected))  // ← the fix
    }

    // MARK: - Empty / nil selection → useAgentDefault

    @Test func nilSelectedModelReturnsUseAgentDefault() {
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: nil,
            currentModelId: "glm-5.2",
            advertisedModelIds: ["glm-5.2"])
        #expect(decision == .useAgentDefault)
    }

    @Test func emptyAdvertisedListReturnsUseAgentDefault() {
        // Agent that didn't advertise a list of models → never override.
        let decision = ACPModelSelectionResolver.resolve(
            selectedModelId: "glm-5.2",
            currentModelId: nil,
            advertisedModelIds: [])
        #expect(decision == .useAgentDefault)
    }
}
