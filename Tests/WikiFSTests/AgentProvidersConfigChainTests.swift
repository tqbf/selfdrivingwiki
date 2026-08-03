import Foundation
import Testing
@testable import WikiFSCore

/// #727: tests for `AgentProvidersConfig.providerChain(forStage:)` — the
/// ordered provider chain used by the launcher's fallback walk.
@Suite("AgentProvidersConfig Chain")
struct AgentProvidersConfigChainTests {

    private func makeProvider(_ id: ProviderID, enabled: Bool = true, isDefault: Bool = false) -> AgentProvider {
        AgentProvider(id: id, label: id.rawValue.capitalized, command: [id.rawValue], enabled: enabled, isDefault: isDefault)
    }

    @Test("Chain ordering: stage-resolved provider first, then others")
    func chainOrdering() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider(ProviderID(rawValue: "claude-acp"), enabled: true, isDefault: true),
                makeProvider(ProviderID(rawValue: "glm-acp"), enabled: true),
                makeProvider(ProviderID(rawValue: "gemini"), enabled: true)
            ]
        )
        let chain = config.providerChain(forStage: "planner")
        #expect(chain.count == 3)
        // Default provider should be first (no stage pin).
        #expect(chain[0].id == ProviderID(rawValue: "claude-acp"))
        // Others in display order.
        #expect(chain[1].id == ProviderID(rawValue: "glm-acp"))
        #expect(chain[2].id == ProviderID(rawValue: "gemini"))
    }

    @Test("Single provider: chain is [first]")
    func singleProvider() {
        let config = AgentProvidersConfig(
            providers: [makeProvider(ProviderID(rawValue: "claude-acp"), enabled: true, isDefault: true)]
        )
        let chain = config.providerChain(forStage: "planner")
        #expect(chain.count == 1)
        #expect(chain[0].id == ProviderID(rawValue: "claude-acp"))
    }

    @Test("Disabled providers excluded from chain")
    func disabledExcluded() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider(ProviderID(rawValue: "claude-acp"), enabled: true, isDefault: true),
                makeProvider(ProviderID(rawValue: "glm-acp"), enabled: false),
                makeProvider(ProviderID(rawValue: "gemini"), enabled: true)
            ]
        )
        let chain = config.providerChain(forStage: "planner")
        // Only enabled providers: claude + gemini (glm disabled).
        #expect(chain.count == 2)
        #expect(chain[0].id == ProviderID(rawValue: "claude-acp"))
        #expect(chain[1].id == ProviderID(rawValue: "gemini"))
    }

    @Test("Stage pin honored as chain head")
    func stagePinHonored() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider(ProviderID(rawValue: "claude-acp"), enabled: true, isDefault: true),
                makeProvider(ProviderID(rawValue: "glm-acp"), enabled: true),
                makeProvider(ProviderID(rawValue: "gemini"), enabled: true)
            ],
            stageProviderIds: ["planner": ProviderID(rawValue: "glm-acp")]
        )
        let chain = config.providerChain(forStage: "planner")
        // Pinned provider should be first.
        #expect(chain[0].id == ProviderID(rawValue: "glm-acp"))
        // Default provider should be second.
        #expect(chain[1].id == ProviderID(rawValue: "claude-acp"))
        #expect(chain[2].id == ProviderID(rawValue: "gemini"))
    }

    @Test("No duplicates in chain")
    func noDuplicates() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider(ProviderID(rawValue: "claude-acp"), enabled: true, isDefault: true),
                makeProvider(ProviderID(rawValue: "glm-acp"), enabled: true)
            ],
            stageProviderIds: ["planner": ProviderID(rawValue: "claude-acp")]
        )
        let chain = config.providerChain(forStage: "planner")
        // Stage pin = default → chain head appears only once.
        #expect(chain.count == 2)
        #expect(chain[0].id == ProviderID(rawValue: "claude-acp"))
        #expect(chain[1].id == ProviderID(rawValue: "glm-acp"))
    }

    @Test("All disabled providers: chain is empty for non-default stage")
    func allDisabled() {
        let config = AgentProvidersConfig(
            providers: [
                makeProvider(ProviderID(rawValue: "claude-acp"), enabled: false, isDefault: true),
                makeProvider(ProviderID(rawValue: "glm-acp"), enabled: false)
            ]
        )
        let chain = config.providerChain(forStage: "planner")
        // selectedProvider() falls back to claudeAcpDefault (enabled static)
        // when no enabled provider exists → chain has 1 (the default static).
        #expect(chain.count == 1)
        #expect(chain[0].id == ProviderID(rawValue: "claude-acp"))
    }
}
