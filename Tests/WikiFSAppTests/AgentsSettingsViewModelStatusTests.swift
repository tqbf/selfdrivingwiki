#if os(macOS)
import Testing
import Foundation
@testable import WikiFS
import WikiFSCore

/// Pure-logic tests for `AgentsSettingsView.modelStatus(for:in:)` — the
/// #663 structured model-status classifier returned to the restructured
/// `ProviderRow`. Sibling to `modelWarning(for:in:)` (correction §6 — both
/// coexist; the warning helper's string-format tests stay load-bearing).
///
/// Same `nonisolated static` shape as `modelWarning`, so these tests call
/// the helper synchronously without a SwiftUI view tree.
@Suite("AgentsSettingsView modelStatus")
struct AgentsSettingsViewModelStatusTests {

    // MARK: - .disabled — disabled providers carry no status line

    @Test func returnsDisabledWhenProviderIsDisabled() {
        // A disabled provider shows no status line — the leading `○` switch
        // glyph already conveys it.
        let disabled = AgentProvider(
            id: "claude-acp", label: "Claude",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
            env: [:], enabled: false, isDefault: false)
        let config = AgentProvidersConfig(providers: [disabled])
        #expect(AgentsSettingsView.modelStatus(for: disabled, in: config) == .disabled)
    }

    // MARK: - .selected — the green dot + model name

    @Test func returnsSelectedWithFriendlyNameWhenModelCached() {
        // When the selected model id matches a cached entry, the status line
        // uses the cache's friendly name (sonnet → "Sonnet 4.5").
        let claude = AgentProvider.claudeAcpDefault
        let config = AgentProvidersConfig(
            providers: [claude],
            providerModels: [
                "claude-acp": [
                    CachedModelInfo(modelId: "sonnet", name: "Sonnet 4.5"),
                    CachedModelInfo(modelId: "opus", name: "Opus 4.5"),
                ]
            ],
            selectedModelIds: ["claude-acp": "sonnet"])
        let status = AgentsSettingsView.modelStatus(for: claude, in: config)
        #expect(status == .selected(name: "Sonnet 4.5"))
    }

    @Test func returnsSelectedWithRawIdWhenCacheStale() {
        // When the selected model isn't in the cache (e.g. the cache was
        // rebuilt but the user's `selectedModelId` predates the rebuild),
        // fall back to the raw id so the dot+label still renders
        // definitively.
        let claude = AgentProvider.claudeAcpDefault
        let config = AgentProvidersConfig(
            providers: [claude],
            providerModels: [
                "claude-acp": [
                    CachedModelInfo(modelId: "sonnet", name: "Sonnet 4.5"),
                ]
            ],
            selectedModelIds: ["claude-acp": "gpt-5"])
        let status = AgentsSettingsView.modelStatus(for: claude, in: config)
        #expect(status == .selected(name: "gpt-5"))
    }

    // MARK: - .noneCaptured — first-spawn state, no cache yet

    @Test func returnsNoneCapturedWhenEnabledNoSelectionNoCache() {
        // First state: enabled + no model + no cached models. The friendly
        // "chat with this provider once to discover models" guidance line.
        // Matches `modelWarning`'s "No model captured yet" branch string-for-
        // string (the sibling helper stays load-bearing — correction §6).
        let provider = AgentProvider(
            id: "gemini", label: "Gemini",
            command: ["gemini", "--acp"],
            env: [:], enabled: true, isDefault: false)
        let config = AgentProvidersConfig(providers: [provider])
        #expect(AgentsSettingsView.modelStatus(for: provider, in: config) == .noneCaptured)
    }

    // MARK: - .noSelectionPickable — cache present, no selection

    @Test func returnsNoSelectionPickableWhenEnabledNoSelectionHasCache() {
        // Second state: enabled + no model + cached models exist. Orange
        // "pick one before running" guidance line — matches `modelWarning`.
        let provider = AgentProvider(
            id: "opencode", label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:], enabled: true, isDefault: false)
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: [
                "opencode": [
                    CachedModelInfo(modelId: "glm-4.7", name: "GLM-4.7"),
                ]
            ])
        #expect(AgentsSettingsView.modelStatus(for: provider, in: config) == .noSelectionPickable)
    }

    // MARK: - Empty-string selection collapses to nil (parity with `modelWarning`)

    @Test func treatsEmptyStringSelectionAsUnselectedWithCachePresent() {
        // `selectedModelId(forProvider:)` returns nil for an empty string,
        // so the status should be `.noSelectionPickable` (cache present) —
        // pinning parity with `modelWarning`'s same-edge-case test.
        let provider = AgentProvider.claudeAcpDefault
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: ["claude-acp": [CachedModelInfo(modelId: "sonnet", name: "Sonnet 4.5")]],
            selectedModelIds: ["claude-acp": ""])
        #expect(AgentsSettingsView.modelStatus(for: provider, in: config) == .noSelectionPickable)
    }

    // MARK: - Stability across providers with the same state

    @Test func statusIsStableAcrossProvidersWithSameState() {
        // Two providers with the same (enabled, no-model, no-cache) state
        // produce the same `.noneCaptured` status — pins the format so a
        // future regression can't special-case a particular provider id.
        let opencode = AgentProvider(
            id: "opencode", label: "OpenCode",
            command: ["opencode", "acp"],
            env: [:], enabled: true, isDefault: false)
        let hermes = AgentProvider(
            id: "hermes", label: "Hermes",
            command: ["hermes", "acp"],
            env: [:], enabled: true, isDefault: false)
        let config = AgentProvidersConfig(providers: [opencode, hermes])
        let opencodeStatus = AgentsSettingsView.modelStatus(for: opencode, in: config)
        let hermesStatus = AgentsSettingsView.modelStatus(for: hermes, in: config)
        #expect(opencodeStatus == hermesStatus)
        #expect(opencodeStatus == .noneCaptured)
    }
}
#endif
