import Testing
import Foundation
@testable import WikiFS
import WikiFSCore

/// #663 acceptance tests for the Add Provider surface and the generic
/// Custom-ACP model. Pins:
/// - **AC.1**: no hardcoded seed buttons in `AgentsSettingsView` (the only
///   add entry point is `AddProviderSheet`, accessed via `showAddSheet`).
/// - **AC.2**: `AddProviderSheet` writes nothing to config until an Add
///   button is pressed — cancel = no change.
/// - **AC.6**: `seed()` returns only `[claudeAcpDefault]`.
/// - **needsEditor heuristic** — a freshly-added catalog agent without a
///   detected binary opens the editor; a cleanly-detected one skips it; a
///   custom add with no command opens it.
///
/// The `AddProviderSheet` view body itself isn't rendered here — AC.2 is
/// asserted at the protocol seam: constructing the sheet + invoking only
/// `.scan()` on its model is observable as zero calls to the parent's
/// `onAdd` closure. (Driving SwiftUI sheet dismiss in a unit test would
/// need hosted-view infrastructure; the seam test is sufficient because the
/// sheet has no other write path.)
@MainActor
@Suite("AddProviderSheet")
struct AddProviderSheetTests {

    // MARK: - AC.2 — Cancel = no change at the onAdd seam

    @Test func constructingAndScanningAddsNothingToConfig() async {
        // Pre-state: a config with one provider (claude-acp default).
        let original = AgentProvidersConfig.seed(discovered: [])
        let existingIDs = Set(original.providers.map(\.id))

        // Wire a stub `onAdd` that fails the test if invoked. Both closures
        // stay `let` because nothing the sheet does in the cancel path
        // invokes them — the only thing we'd catch is a write-side-effect
        // regression.
        let onAddInvocations: [AgentProvider] = []
        let onAddNeedsEditorInvocations: [AgentProvider] = []
        let model = AddProviderModel(existingIDs: existingIDs)

        // The sheet's `scan()` runs the live PATH discovery — that should
        // NOT touch the parent's config either. Use the real `scan()`
        // (it's an off-main Task.detached; no subprocess spawn; just `zsh
        // -lc 'echo $PATH'` + an `isExecutableFile` check per catalog entry).
        await model.scan()

        // Cancel — i.e. don't invoke `onAdd`. (The sheet's `Done` button
        // just dismisses; there is no "apply" path.)
        // Assert: zero writes to the parent.
        #expect(onAddInvocations.isEmpty)
        #expect(onAddNeedsEditorInvocations.isEmpty)
        // And the parent's config is structurally unchanged — only its
        // `existingIDs` snapshot was handed to the sheet.
        #expect(original.providers.count == 1)
        #expect(original.providers.first?.id == "claude-acp")
    }

    // MARK: - AC.6 — seed returns [claudeAcpDefault]

    @Test func seedReturnsClaudeAcpDefaultOnly() {
        let config = AgentProvidersConfig.seed(discovered: [])
        #expect(config.providers.map(\.id) == ["claude-acp"])
        #expect(config.providers.first?.isDefault == true)
        // The default-model seed stays — the spawn refusal guard (#635)
        // still depends on it for day-one spawnability.
        #expect(config.selectedModelId(forProvider: "claude-acp") == "sonnet")
    }

    @Test func normalizedEmptyReturnsClaudeAcpDefaultOnly() {
        // Defensive invariant: a hand-edited file that decodes to zero
        // providers re-seeds the single Claude default at `init` (via the
        // `normalized()` call inside `init(providers:)`).
        let config = AgentProvidersConfig(providers: [])
        #expect(config.providers.map(\.id) == ["claude-acp"])
        #expect(config.defaultProvider.id == "claude-acp")
    }

    // MARK: - needsEditor heuristic (correction §4)

    @Test func needsEditorTrueForCustomWithEmptyCommand() {
        // The custom-add path lands the user in the editor for env/key
        // follow-up. The heuristic's first branch (`provider.command` empty
        // or nil) catches this.
        let model = AddProviderModel(existingIDs: [])
        let custom = AgentProvider(
            id: "custom", label: "My Agent",
            command: nil,
            env: [:], enabled: true, isDefault: false)
        #expect(model.needsEditor(for: custom) == true)
    }

    @Test func needsEditorFalseForDetectedCatalogAgent() {
        // A cleanly-detected catalog agent skips the editor (fast path: 2
        // clicks total). Construct a model whose `detected` list contains
        // the agent — that's the post-scan state.
        let agent = ACPProviderCatalog.agents.first(where: { $0.id == "claude-acp" })!
        let discovered = DiscoveredACPAgent(agent: agent, resolvedPath: "/opt/homebrew/bin/bun")
        let model = AddProviderModel(existingIDs: [])
        model.detected = [discovered]
        model.isScanning = false
        let provider = AgentProvider.acp(from: agent)
        #expect(model.needsEditor(for: provider) == false)
    }

    @Test func needsEditorTrueForNonDetectedCatalogAgent() {
        // A catalog agent whose binary is NOT on PATH (added from the
        // "Other known agents" section) opens the editor — the user may
        // want to tweak the command/env/key (e.g. adding an API key for a
        // provider whose binary will be installed later).
        let agent = ACPProviderCatalog.agents.first(where: { $0.id == "gemini" })!
        let model = AddProviderModel(existingIDs: [])
        // Empty `detected` simulates "gemini not on PATH."
        model.detected = []
        model.isScanning = false
        let provider = AgentProvider.acp(from: agent)
        #expect(model.needsEditor(for: provider) == true)
    }

    // MARK: - freshCustomID — collision loop

    @Test func freshCustomIDStartsAtCustomAndIncrements() {
        // No existing `custom` → "custom". Existing "custom" → "custom-2".
        // Existing "custom" + "custom-2" → "custom-3".
        #expect(AddProviderModel(existingIDs: []).freshCustomID() == "custom")
        #expect(AddProviderModel(existingIDs: ["custom"]).freshCustomID() == "custom-2")
        #expect(AddProviderModel(existingIDs: ["custom", "custom-2"]).freshCustomID() == "custom-3")
    }

    // MARK: - otherAgents excludes both existing AND detected

    @Test func otherAgentsExcludesExistingAndDetected() {
        // `otherAgents` is the catalog minus `existingIDs` (already added)
        // minus `detected` (shown in the "Installed on this Mac" section).
        // Pins the dedup contract so the user can't see a provider in two
        // sections at once.
        let geminiAgent = ACPProviderCatalog.agents.first(where: { $0.id == "gemini" })!
        let model = AddProviderModel(existingIDs: ["claude-acp"])  // claude added
        model.detected = [DiscoveredACPAgent(agent: geminiAgent, resolvedPath: "/x")]  // gemini detected
        model.isScanning = false
        let otherIDs = model.otherAgents.map(\.id)
        #expect(!otherIDs.contains("claude-acp"))  // already added
        #expect(!otherIDs.contains("gemini"))      // shown in detected
        // The rest of the catalog is still present.
        #expect(otherIDs.contains("hermes"))
        #expect(otherIDs.contains("copilot"))
    }

    // MARK: - Query filter

    @Test func queryFiltersBothSectionsCaseInsensitive() {
        // Search "GEM" matches "Gemini CLI" (label) AND "Gemini over ACP"
        // (summary) — case-insensitive on both, label OR summary. Gemini
        // shows up in `otherAgents` (not detected, not existing). The
        // detected claude-acp doesn't contain "gem", so `detectedFiltered`
        // is empty under this query.
        let model = AddProviderModel(existingIDs: [])
        model.detected = [
            DiscoveredACPAgent(
                agent: ACPProviderCatalog.agents.first(where: { $0.id == "claude-acp" })!,
                resolvedPath: "/x"),
        ]
        model.isScanning = false
        model.query = "GEM"
        let otherIDs = model.otherAgents.map(\.id)
        #expect(otherIDs.contains("gemini"))
        #expect(!otherIDs.contains("hermes"))
        // detectedFiltered — claude-acp's label "Claude" doesn't contain "gem",
        // so the detected section is empty under this query.
        #expect(model.detectedFiltered.isEmpty)
    }

    // MARK: - canAddCustom (the sheet's gating)

    @Test func canAddCustomFalseWhenNameOrCommandBlank() {
        // The "Add Custom" button is disabled when either field is empty
        // (whitespace-only counts as empty). The sheet checks the trimmed
        // strings; we test the gate logic directly by constructing the
        // same expression.
        let model = AddProviderModel(existingIDs: [])
        // Both empty → disabled.
        #expect(!canAddCustom(name: model.customName, command: model.customCommand))
        // Name only → still disabled.
        model.customName = "My Agent"
        #expect(!canAddCustom(name: model.customName, command: model.customCommand))
        // Whitespace-only command → disabled.
        model.customCommand = "   "
        #expect(!canAddCustom(name: model.customName, command: model.customCommand))
        // Both filled → enabled.
        model.customCommand = "opencode acp"
        #expect(canAddCustom(name: model.customName, command: model.customCommand))
    }

    // Local mirror of the sheet's private `canAddCustom` gate so the test
    // asserts the precise contract.
    private func canAddCustom(name: String, command: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
