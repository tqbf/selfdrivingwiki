#if os(macOS)
import Testing
import WikiFSEngine
import Foundation
import WikiFSEngine
import ACPModel
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// v1 provider-selector tests (#325): the `settingDefault(id:)` mutator on
/// `AgentProvidersConfig` (the single-default invariant), the
/// `enabledProviders` view the selector binds to, and the round-trip through
/// the launcher's `setDefaultProvider(id:)` → `resolveSelectedProvider` (the
/// wiring the composer selector relies on so a picked provider becomes the next
/// session's backend). Pure logic only — no live agent subprocess.
@Suite struct ProviderSelectorDefaultTests {

    // MARK: - Chat model label presentation

    @Test func codexStructuredModelIDsGroupWithoutLiveThinkingMetadata() {
        let models = [
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt-5.6-sol[low]"),
                name: "GPT-5.6-Sol (low)"),
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt-5.6-sol[high]"),
                name: "GPT-5.6-Sol (high)"),
        ]
        let low = ChatConfigurationValueID(rawValue: "low")
        let high = ChatConfigurationValueID(rawValue: "high")
        let capability = ThinkingCapabilityCatalog(
            choices: [
                ThinkingOptionCatalogChoice(id: low, label: "Low"),
                ThinkingOptionCatalogChoice(id: high, label: "High"),
            ],
            mechanism: .modelVariants(valueToModelID: [
                low: models[0].modelId,
                high: models[1].modelId,
            ]),
            source: .agentAdapter(adapterID: ThinkingCapabilityAdapterID(rawValue: "codex")),
            displayAliases: ["low", "Low", "high", "High"])
        let resolution = ThinkingSelectionResolution(
            capability: capability,
            configuredValueID: high,
            effectiveValueID: high)
        let families = ProviderSelector.modelFamilies(
            from: models,
            resolution: resolution)

        #expect(families.count == 1)
        #expect(families[0].label == "GPT-5.6-Sol")
        #expect(families[0].selectedModel.modelId == ModelID(rawValue: "gpt-5.6-sol[high]"))
    }

    @Test func modelFamiliesDoNotUseDisplaySuffixesWithoutMappedMechanism() {
        let models = [
            CachedModelInfo(modelId: ModelID(rawValue: "luna-low"), name: "GPT-5.6-Luna (Low)"),
            CachedModelInfo(modelId: ModelID(rawValue: "luna-high"), name: "GPT-5.6-Luna (High)"),
        ]
        let resolution = ThinkingSelectionResolution(
            capability: nil,
            configuredValueID: ChatConfigurationValueID(rawValue: "high"),
            effectiveValueID: nil)
        let families = ProviderSelector.modelFamilies(
            from: models,
            resolution: resolution)

        #expect(families.count == 2)
        #expect(families.map(\.label) == ["GPT-5.6-Luna (Low)", "GPT-5.6-Luna (High)"])
    }

    // MARK: - settingDefault (single-default invariant)

    /// Setting a provider as default demotes every other provider — exactly one
    /// default survives.
    @Test func settingDefaultDemotesOthers() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude"), label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: ProviderID(rawValue: "gemini"), label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
            AgentProvider(id: ProviderID(rawValue: "hermes"), label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
        ])

        let updated = config.settingDefault(id: ProviderID(rawValue: "gemini"))

        #expect(updated.defaultProvider.id == ProviderID(rawValue: "gemini"))
        // Single-default invariant: exactly one.
        let defaults = updated.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        // The previous default (Claude) lost it.
        #expect(updated.provider(id: ProviderID(rawValue: "claude"))?.isDefault == false)
        #expect(updated.provider(id: ProviderID(rawValue: "hermes"))?.isDefault == false)
        // selectedProvider() now resolves to the picked one (it's enabled).
        #expect(updated.selectedProvider().id == ProviderID(rawValue: "gemini"))
    }

    /// Switching the default twice returns to the original: the mutator is
    /// idempotent w.r.t. the invariant and reversible.
    @Test func settingDefaultIsReversible() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude"), label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: ProviderID(rawValue: "gemini"), label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])

        let switched = config.settingDefault(id: ProviderID(rawValue: "gemini"))
        #expect(switched.defaultProvider.id == ProviderID(rawValue: "gemini"))

        let back = switched.settingDefault(id: ProviderID(rawValue: "claude"))
        #expect(back.defaultProvider.id == ProviderID(rawValue: "claude"))
        #expect(back.provider(id: ProviderID(rawValue: "gemini"))?.isDefault == false)
    }

    /// Setting an UNKNOWN id as default does not collapse to zero defaults —
    /// normalization promotes the first enabled provider, so the selector
    /// never strands the launcher with no provider.
    @Test func settingDefaultUnknownIdKeepsInvariant() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude"), label: "Claude", enabled: true, isDefault: true),
        ])

        let updated = config.settingDefault(id: ProviderID(rawValue: "does-not-exist"))

        let defaults = updated.providers.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(updated.defaultProvider.id == ProviderID(rawValue: "claude"))
    }

    /// The mutator is PURE: the original config is untouched (returns a new
    /// value). This is what lets the selector bind a fresh @State without
    /// mutating the source.
    @Test func settingDefaultIsPure() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude"), label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: ProviderID(rawValue: "gemini"), label: "Gemini", command: ["gemini", "--acp"], enabled: true, isDefault: false),
        ])

        _ = config.settingDefault(id: ProviderID(rawValue: "gemini"))

        // Original unchanged: claude is still default.
        #expect(config.defaultProvider.id == ProviderID(rawValue: "claude"))
        #expect(config.provider(id: ProviderID(rawValue: "gemini"))?.isDefault == false)
    }

    // MARK: - enabledProviders (the selector's pickable list)

    /// `enabledProviders` excludes disabled providers, matching the launcher's
    /// `selectedProvider()` fallback (it never launches a disabled one). The
    /// selector menu must agree, or it could show a provider that won't run.
    @Test func enabledProvidersExcludesDisabled() {
        let config = AgentProvidersConfig(providers: [
            AgentProvider(id: ProviderID(rawValue: "claude"), label: "Claude", enabled: true, isDefault: true),
            AgentProvider(id: ProviderID(rawValue: "gemini"), label: "Gemini", command: ["gemini", "--acp"], enabled: false, isDefault: false),
            AgentProvider(id: ProviderID(rawValue: "hermes"), label: "Hermes", command: ["hermes", "acp"], enabled: true, isDefault: false),
        ])

        let ids = config.enabledProviders.map(\.id)
        #expect(ids == [ProviderID(rawValue: "claude"), ProviderID(rawValue: "hermes")])
        #expect(!ids.contains(ProviderID(rawValue: "gemini")))
    }

    /// selector ever having run.
    @MainActor
    @Test func launcherDefaultsToClaudeAcpWhenUnpicked() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-launcher-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let launcher = AgentLauncher()
        launcher.resolveProvidersContainerDirectory = { tmp }
        launcher.resolveSelectedProvider = {
            AgentProvidersConfig.loadOrSeed(from: tmp, discover: { [] }).selectedProvider()
        }

        // providersConfig() seeds + persists on first read; no pick made.
        let config = launcher.providersConfig()
        #expect(config.defaultProvider.id == ProviderID(rawValue: "claude-acp"))
        #expect(launcher.resolveSelectedProvider().id == ProviderID(rawValue: "claude-acp"))
    }
}
#endif
