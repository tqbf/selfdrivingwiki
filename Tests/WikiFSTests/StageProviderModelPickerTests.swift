import Testing
import Foundation
@testable import WikiFSCore

/// `plans/agent-settings-tabs.md` §7: pure-logic tests for the per-stage
/// provider + model resolution that backs `StageProviderModelPicker`. The View
/// itself can't be render-tested (no SwiftUI snapshot harness); these tests
/// pin the resolvers (`provider(forStage:)`, `modelId(forStage:)`) the View
/// reads so the dropdown behavior is covered. NO subprocess — pure config.
@Suite("StageProviderModelPicker resolver logic")
struct StageProviderModelPickerTests {

    // MARK: - Fixture

    /// Two enabled providers + one disabled, each with a cached model catalog,
    /// and a selected model per provider. Lets every resolution branch fire.
    private var fixture: AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [
                AgentProvider(
                    id: "alpha", label: "Alpha",
                    command: ["alpha", "acp"], env: [:],
                    enabled: true, isDefault: true),
                AgentProvider(
                    id: "beta", label: "Beta",
                    command: ["beta", "acp"], env: [:],
                    enabled: true, isDefault: false),
                AgentProvider(
                    id: "gamma", label: "Gamma",
                    command: ["gamma", "acp"], env: [:],
                    enabled: false, isDefault: false),
            ],
            providerModels: [
                "alpha": [
                    CachedModelInfo(modelId: "a-1", name: "A One", description: nil),
                    CachedModelInfo(modelId: "a-2", name: "A Two", description: nil),
                ],
                "beta": [
                    CachedModelInfo(modelId: "b-1", name: "B One", description: nil),
                ]
            ],
            selectedModelIds: [
                "alpha": "a-1",
                "beta": "b-1",
            ])
    }

    // MARK: - Provider resolution: "" sentinel → global default

    @Test func providerForStageWithEmptyPinReturnsGlobalDefault() {
        let config = fixture
        // No pin → the global default (alpha).
        #expect(config.provider(forStage: "chat") == config.providers[0])
        #expect(config.provider(forStage: "lint").id == "alpha")
        #expect(config.provider(forStage: "planner").id == "alpha")
    }

    @Test func providerForStageWithMissingPinReturnsGlobalDefault() {
        // A stage with NO entry at all behaves like the "" sentinel.
        let config = fixture
        #expect(config.stageProviderIds["chat"] == nil)
        #expect(config.provider(forStage: "chat").id == "alpha")
    }

    // MARK: - Provider resolution: enabled pin → that provider

    @Test func providerForStageWithEnabledPinReturnsPinned() {
        let config = fixture.settingStageProvider("beta", forStage: "chat")
        #expect(config.provider(forStage: "chat").id == "beta")
    }

    // MARK: - Provider resolution: disabled pin → fall back to default

    @Test func providerForStageWithDisabledPinFallsBackToDefault() {
        // gamma is disabled — a pin to it MUST fall back to the global default
        // (the launcher never selects a disabled provider). This is the
        // critical guard against routing to a provider that can't spawn.
        let config = fixture.settingStageProvider("gamma", forStage: "lint")
        #expect(config.provider(forStage: "lint").id == "alpha")
    }

    // MARK: - Model resolution: "" sentinel → provider's selectedModelId

    @Test func modelForStageWithNoOverrideReturnsProvidersSelectedModel() {
        let config = fixture
        // No model override for chat → the chat stage's resolved provider's
        // selectedModelId. Default provider is alpha → "a-1".
        #expect(config.modelId(forStage: "chat") == "a-1")
    }

    @Test func modelForStageWithProviderPinUsesThatProvidersSelectedModel() {
        // Pin chat to beta → the fallback is beta's selectedModelId ("b-1").
        let config = fixture.settingStageProvider("beta", forStage: "chat")
        #expect(config.modelId(forStage: "chat") == "b-1")
    }

    @Test func modelForStageOverrideWinsOverProviderFallback() {
        // A stage model override takes precedence over the provider's
        // selectedModelId.
        let config = fixture
            .settingStageProvider("beta", forStage: "chat")
            .settingIngestStageModel("b-1", forStage: "chat")
        #expect(config.modelId(forStage: "chat") == "b-1")
    }

    @Test func modelForStageReturnsNilWhenProviderHasNoSelection() {
        // A provider with no selectedModelId and no stage override → nil (the
        // agent's default model). Mirrors the legacy "no selection" behavior.
        let config = AgentProvidersConfig(
            providers: [AgentProvider(id: "p", label: "P", command: ["p"], enabled: true, isDefault: true)])
        #expect(config.modelId(forStage: "chat") == nil)
    }

    // MARK: - Cached models follow the resolved provider

    @Test func cachedModelsFollowResolvedProvider() {
        // The model dropdown reads `cachedModels(forProvider: resolvedProvider.id)`.
        // With no pin → alpha's catalog; pin chat to beta → beta's catalog.
        let pinned = fixture.settingStageProvider("beta", forStage: "chat")
        #expect(fixture.cachedModels(forProvider: fixture.provider(forStage: "chat").id).count == 2)
        #expect(pinned.cachedModels(forProvider: pinned.provider(forStage: "chat").id).count == 1)
    }

    // MARK: - Stages are independent

    @Test func stagesAreIndependent() {
        // Chat pinned to beta, lint pinned to default, planner pinned to beta.
        let config = fixture
            .settingStageProvider("beta", forStage: "chat")
            .settingStageProvider("beta", forStage: "planner")
        #expect(config.provider(forStage: "chat").id == "beta")
        #expect(config.provider(forStage: "lint").id == "alpha")
        #expect(config.provider(forStage: "planner").id == "beta")
    }
}
