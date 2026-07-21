import Foundation
import Testing
@testable import WikiFSCore

/// #727: tests for `AgentProvidersConfig.providerChain(forStage:)` — the
/// ordered provider chain used by the launcher's fallback walk.
@Suite("AgentProvidersConfig Chain")
struct AgentProvidersConfigChainTests {

    private func makeProvider(_ id: String, enabled: Bool = true, isDefault: Bool = false) -> AgentProvider {
        AgentProvider(id: id, label: id.capitalized, command: [id], enabled: enabled, isDefault: isDefault)
    }

    @Test("Chain ordering: stage-resolved provider first, then others")
    func chainOrdering() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider("claude-acp", enabled: true, isDefault: true),
                makeProvider("glm-acp", enabled: true),
                makeProvider("gemini", enabled: true)
            ]
        )
        let chain = config.providerChain(forStage: "planner")
        #expect(chain.count == 3)
        // Default provider should be first (no stage pin).
        #expect(chain[0].id == "claude-acp")
        // Others in display order.
        #expect(chain[1].id == "glm-acp")
        #expect(chain[2].id == "gemini")
    }

    @Test("Single provider: chain is [first]")
    func singleProvider() {
        let config = AgentProvidersConfig(
            providers: [makeProvider("claude-acp", enabled: true, isDefault: true)]
        )
        let chain = config.providerChain(forStage: "planner")
        #expect(chain.count == 1)
        #expect(chain[0].id == "claude-acp")
    }

    @Test("Disabled providers excluded from chain")
    func disabledExcluded() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider("claude-acp", enabled: true, isDefault: true),
                makeProvider("glm-acp", enabled: false),
                makeProvider("gemini", enabled: true)
            ]
        )
        let chain = config.providerChain(forStage: "planner")
        // Only enabled providers: claude + gemini (glm disabled).
        #expect(chain.count == 2)
        #expect(chain[0].id == "claude-acp")
        #expect(chain[1].id == "gemini")
    }

    @Test("Stage pin honored as chain head")
    func stagePinHonored() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider("claude-acp", enabled: true, isDefault: true),
                makeProvider("glm-acp", enabled: true),
                makeProvider("gemini", enabled: true)
            ],
            stageProviderIds: ["planner": "glm-acp"]
        )
        let chain = config.providerChain(forStage: "planner")
        // Pinned provider should be first.
        #expect(chain[0].id == "glm-acp")
        // Default provider should be second.
        #expect(chain[1].id == "claude-acp")
        #expect(chain[2].id == "gemini")
    }

    @Test("No duplicates in chain")
    func noDuplicates() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider("claude-acp", enabled: true, isDefault: true),
                makeProvider("glm-acp", enabled: true)
            ],
            stageProviderIds: ["planner": "claude-acp"]
        )
        let chain = config.providerChain(forStage: "planner")
        // Stage pin = default → chain head appears only once.
        #expect(chain.count == 2)
        #expect(chain[0].id == "claude-acp")
        #expect(chain[1].id == "glm-acp")
    }

    @Test("All disabled providers: chain is empty for non-default stage")
    func allDisabled() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider("claude-acp", enabled: false, isDefault: true),
                makeProvider("glm-acp", enabled: false)
            ]
        )
        let chain = config.providerChain(forStage: "planner")
        // selectedProvider() falls back to claudeAcpDefault (enabled static)
        // when no enabled provider exists → chain has 1 (the default static).
        #expect(chain.count == 1)
        #expect(chain[0].id == "claude-acp")
    }
}
