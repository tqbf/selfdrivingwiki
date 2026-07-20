import Testing
import Foundation
@testable import WikiFSEngine
@testable import WikiFSCore

/// `plans/agent-settings-tabs.md` §3 (HIGH #2 — the shared `run()` dispatch):
/// verifies `AgentLauncher.stageKey(for:)` maps each `OperationRequest` kind to
/// the correct per-stage key. The shared `run()` one-shot entry serves
/// `.ingest` / `.query` / `.lint` / `.lintPage`; deriving the WRONG key would
/// mis-route operations to the wrong stage's pinned provider (e.g. a query
/// silently using the lint provider). These tests pin the mapping without a
/// subprocess — `stageKey(for:)` is pure + static.
@Suite("AgentLauncher.stageKey dispatch (run() shared path)")
struct AgentLauncherStageKeyDispatchTests {

    private let emptyState = ""
    private let emptySource = OperationRequest.StagedSource(
        bytes: Data(), ext: "md", displayPath: "x.md", name: "x", sourceID: "ulid")

    @Test func ingestMapsToPlanner() {
        // Small-source OR large-source ingest (the large/small split is
        // decided later inside run() after staging) — both derive "planner"
        // here. Large-source ingest then branches to the orchestrator which
        // resolves per-phase; small-source uses this key end-to-end.
        let key = AgentLauncher.stageKey(for: .ingest(sources: [emptySource], stateMarkdown: emptyState))
        #expect(key == "planner")
    }

    @Test func lintMapsToLint() {
        #expect(AgentLauncher.stageKey(for: .lint(stateMarkdown: emptyState)) == "lint")
    }

    @Test func lintPageMapsToLint() {
        #expect(AgentLauncher.stageKey(for: .lintPage(pageTitle: "P", brokenLinks: [], stateMarkdown: emptyState)) == "lint")
    }

    @Test func queryMapsToChat() {
        // One-shot query (NOT interactive chat — that's startInteractiveQuery,
        // which hardcodes the "chat" stage independently). A one-shot query
        // routed through run() uses the chat stage key so it respects a
        // chat-pinned provider.
        #expect(AgentLauncher.stageKey(for: .query(question: "Q", stateMarkdown: emptyState)) == "chat")
    }

    // MARK: - Dispatch correctness vs. the lint stage (the reviewer's concern)

    @Test func smallSourceIngestDoesNotRouteToLintStage() {
        // The reviewer's explicit worry: hardcoding "lint" in run() would
        // mis-route small-source ingest to the lint provider. The mapping
        // MUST be "planner", so a lint-stage provider pin does NOT affect
        // ingest. Configured with a lint pin, the planner stage (used by
        // ingest) resolves to the global default, NOT the lint pin.
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "def", label: "Def", command: ["d"], enabled: true, isDefault: true),
                AgentProvider(id: "linter", label: "Linter", command: ["l"], enabled: true, isDefault: false),
            ],
            stageProviderIds: ["lint": "linter"])
        let ingestKey = AgentLauncher.stageKey(for: .ingest(sources: [emptySource], stateMarkdown: emptyState))
        #expect(ingestKey == "planner")
        // Ingest's resolved provider is the default (def), NOT the linter.
        #expect(config.provider(forStage: ingestKey).id == "def")
    }

    @Test func queryDoesNotRouteToLintStage() {
        // A one-shot query must NOT pick up the lint stage's pinned provider.
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "def", label: "Def", command: ["d"], enabled: true, isDefault: true),
                AgentProvider(id: "linter", label: "Linter", command: ["l"], enabled: true, isDefault: false),
            ],
            stageProviderIds: ["lint": "linter"])
        let queryKey = AgentLauncher.stageKey(for: .query(question: "Q", stateMarkdown: emptyState))
        #expect(queryKey == "chat")
        #expect(config.provider(forStage: queryKey).id == "def")
    }

    @Test func lintRoutesToLintStage() {
        // Lint MUST use the lint stage's pinned provider when set.
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: "def", label: "Def", command: ["d"], enabled: true, isDefault: true),
                AgentProvider(id: "linter", label: "Linter", command: ["l"], enabled: true, isDefault: false),
            ],
            stageProviderIds: ["lint": "linter"])
        let lintKey = AgentLauncher.stageKey(for: .lint(stateMarkdown: emptyState))
        #expect(lintKey == "lint")
        #expect(config.provider(forStage: lintKey).id == "linter")
    }
}
