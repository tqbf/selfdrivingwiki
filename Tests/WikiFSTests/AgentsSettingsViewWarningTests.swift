import Testing
import Foundation
@testable import WikiFS
import WikiFSCore

/// Pure-logic tests for `AgentsSettingsView.modelWarning(for:in:)`.
///
/// The helper drives the orange "no model picked" caption shown below a
/// provider's command line in Settings → Agents. Extracted as a STATIC pure
/// function (taking the config as a parameter) so it can be tested without
/// rendering. The row calls `Self.modelWarning(for: provider, in: config)`
/// with the same `@State var config` source the view stores.
@Suite("AgentsSettingsView modelWarning")
struct AgentsSettingsViewWarningTests {

    // MARK: - Returns nil when no warning is needed

    @Test func returnsNilWhenProviderDisabled() {
        // A disabled provider can't spawn, so the warning is redundant.
        let disabledClaude = AgentProvider(
            id: "claude-acp", label: "Claude",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
            env: [:], enabled: false, isDefault: false)
        let config = AgentProvidersConfig(providers: [disabledClaude])
        #expect(AgentsSettingsView.modelWarning(for: disabledClaude, in: config) == nil)
    }

    @Test func returnsNilWhenModelSelected() {
        // An enabled provider with a selected model has nothing to warn about.
        let claude = AgentProvider.claudeAcpDefault
        let config = AgentProvidersConfig(
            providers: [claude],
            selectedModelIds: ["claude-acp": "sonnet"])
        #expect(AgentsSettingsView.modelWarning(for: claude, in: config) == nil)
    }

    @Test func returnsNilWhenEmptyStringModelSelectedIsTreatedAsNoModelButStillWarns() {
        // An empty-string model id collapses to nil at the config layer
        // (`selectedModelId(forProvider:)` returns nil for empty), so the
        // warning should fire — pinning the contract.
        let claude = AgentProvider.claudeAcpDefault
        let config = AgentProvidersConfig(
            providers: [claude],
            // We don't set the empty string directly because setting mutators
            // strip empties; mirror what a hand-edited file with an empty
            // selectedModelId value would decode to.
            selectedModelIds: ["claude-acp": ""])
        #expect(AgentsSettingsView.modelWarning(for: claude, in: config) != nil)
    }

    // MARK: - "No model captured yet" — the friendly discovery hint

    @Test func returnsNoModelCapturedWhenEnabledNoSelectionNoCache() {
        // The first state: enabled + no model + no cached models. The friendly
        // guidance line ("chat with this provider once to discover models")
        // is what users of a freshly-added provider see.
        let opencode = AgentProvider.opencodeDefault
        let config = AgentProvidersConfig(providers: [opencode])
        let msg = AgentsSettingsView.modelWarning(for: opencode, in: config)
        #expect(msg != nil)
        #expect(msg?.contains("No model captured yet") == true)
        #expect(msg?.contains("discover models") == true)
    }

    // MARK: - "No model selected" — the actionable "pick one" message

    @Test func returnsNoModelSelectedWhenEnabledNoSelectionHasCache() {
        // The second state: enabled + no model + cached models exist. The user
        // has discoverable models and just needs to pick one. Warning is the
        // more direct "pick one before running".
        let opencode = AgentProvider.opencodeDefault
        let config = AgentProvidersConfig(
            providers: [opencode],
            providerModels: [
                "opencode": [
                    CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7"),
                    CachedModelInfo(modelId: "opencode/big-pickle", name: "Big Pickle"),
                ]
            ])
        let msg = AgentsSettingsView.modelWarning(for: opencode, in: config)
        #expect(msg != nil)
        #expect(msg?.contains("No model selected") == true)
        #expect(msg?.contains("pick one before running") == true)
    }

    // MARK: - Provider-label independence (the warning is action-shaped, not label-shaped)

    @Test func warningIsStableAcrossProvidersWithSameState() {
        // Two providers with the same (enabled, no-model, no-cache) state get
        // the same warning string. Pins the format so UI snapshot tests could
        // pin it without surprising changes per-provider.
        let opencode = AgentProvider.opencodeDefault
        let hermes = AgentProvider.hermesDefault
        let config = AgentProvidersConfig(providers: [opencode, hermes])
        #expect(
            AgentsSettingsView.modelWarning(for: opencode, in: config)
            == AgentsSettingsView.modelWarning(for: hermes, in: config))
    }
}
