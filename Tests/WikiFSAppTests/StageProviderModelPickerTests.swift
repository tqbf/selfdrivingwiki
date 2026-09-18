#if os(macOS)
import Testing
import WikiFSCore
@testable import WikiFS

struct StageProviderModelPickerTests {

    @Test func selectionStateUsesInheritedWhenNoPinExists() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude", enabled: true, isDefault: true),
        ])

        let state = StageProviderSelectionState.resolve(config: config, stageKey: "summarizer")

        #expect(state == .inherited)
    }

    @Test func selectionStateKeepsEnabledPinnedProvider() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: ProviderID(rawValue: "gemini"), label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])
        .settingStageProvider(ProviderID(rawValue: "gemini"), forStage: "summarizer")

        let state = StageProviderSelectionState.resolve(config: config, stageKey: "summarizer")

        #expect(state == .pinnedEnabled(id: "gemini"))
    }

    @Test func selectionStateSurfacesDisabledPinnedProvider() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: ProviderID(rawValue: "gemini"), label: "Gemini", command: ["gemini", "--acp"], enabled: false, isDefault: false),
        ])
        .settingStageProvider(ProviderID(rawValue: "gemini"), forStage: "summarizer")

        let state = StageProviderSelectionState.resolve(config: config, stageKey: "summarizer")

        #expect(state == .pinnedDisabled(id: "gemini", label: "Gemini"))
    }

    @Test func selectionStateSurfacesMissingPinnedProvider() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude", enabled: true, isDefault: true),
        ])
        .settingStageProvider(ProviderID(rawValue: "gemini"), forStage: "summarizer")

        let state = StageProviderSelectionState.resolve(config: config, stageKey: "summarizer")

        #expect(state == .pinnedMissing(id: "gemini"))
    }

    @Test func selectionStateRecognizesTheReservedAppleIntelligencePin() {
        // The reserved built-in is not a configured provider, so it must
        // resolve to its own state — NOT `pinnedMissing`, which would show the
        // orange "no longer exists" warning (plans/apple-intelligence-summarizer.md).
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude-acp"), label: "Claude", enabled: true, isDefault: true),
        ])
        .settingStageProvider(.appleIntelligence, forStage: "summarizer")

        let state = StageProviderSelectionState.resolve(config: config, stageKey: "summarizer")

        #expect(state == .pinnedAppleIntelligence)
        #expect(!state.isUnavailable)
    }
}
#endif
