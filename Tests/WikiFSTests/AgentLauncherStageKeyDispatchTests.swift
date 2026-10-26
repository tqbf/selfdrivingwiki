#if os(macOS)
import Testing
import Foundation
@testable import WikiFSEngine
@testable import WikiFSCore

/// `plans/agent-settings-tabs.md` §3 (HIGH #2 — the shared `run()` dispatch):
/// verifies `AgentLauncher.stageKey(for:)` maps each `OperationRequest` kind to
/// the correct per-stage key. The shared `run()` one-shot entry serves
/// `.ingest` / `.query` (the queued lint lane is retired); deriving the WRONG
/// key would mis-route operations to the wrong stage's pinned provider. These
/// tests pin the mapping without a subprocess — `stageKey(for:)` is pure +
/// static.
@Suite("AgentLauncher.stageKey dispatch (run() shared path)")
struct AgentLauncherStageKeyDispatchTests {

    private let emptyState = ""
    private let emptySource = OperationRequest.StagedSource(
        bytes: Data(), ext: "md", displayPath: "x.md", name: "x", sourceID: SourceID(rawValue: "ulid"))

    @Test func ingestMapsToPlanner() {
        // Small-source OR large-source ingest (the large/small split is
        // decided later inside run() after staging) — both derive "planner"
        // here. Large-source ingest then branches to the orchestrator which
        // resolves per-phase; small-source uses this key end-to-end.
        let key = AgentLauncher.stageKey(for: .ingest(sources: [emptySource], stateMarkdown: emptyState))
        #expect(key == "planner")
    }

    @Test func ingestRequestSerializesSourceIDsInDeclaredQueueOrder() {
        let first = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "first.md", name: "first",
            sourceID: SourceID(rawValue: "a"))
        let second = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "second.md", name: "second",
            sourceID: SourceID(rawValue: "b"))

        let environment = AgentLauncher.ingestProvenanceEnvironment(
            for: .ingest(sources: [first, second], stateMarkdown: ""))

        #expect(environment == [
            "WIKI_INGEST_SOURCE_IDS": "a,b",
            "WIKI_AUTHOR": "agent:ingest",
        ])
    }

    /// #1367 review (PR #1369): the ingest env seam is the ONE place the run
    /// author enters the pipeline — every planner/executor/finalizer spawn
    /// composes through `ingestProvenanceProviderHints`. Pin the exact value
    /// (`PageAuthor.agent("ingest")`, matching what the one-shot path stamps)
    /// so the seam can never stamp a divergent or missing author, and pin
    /// that non-ingest requests leave the author to the one-shot site.
    @Test func ingestEnvironmentStampsRunAuthorForEveryPhaseShape() {
        let source = OperationRequest.StagedSource(
            bytes: Data(), ext: "md", displayPath: "x.md", name: "x",
            sourceID: SourceID(rawValue: "ulid"))

        let ingest = AgentLauncher.ingestProvenanceEnvironment(
            for: .ingest(sources: [source], stateMarkdown: ""))
        #expect(ingest[AgentLauncher.wikiAuthorEnvironmentKey]
                == PageAuthor.agent("ingest").rawValue)

        let query = AgentLauncher.ingestProvenanceEnvironment(
            for: .query(question: "Q", stateMarkdown: ""))
        #expect(query.isEmpty, "non-ingest requests stamp neither source ids nor author here")
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
                AgentProvider(id: ProviderID(rawValue: "def"), label: "Def", command: ["d"], enabled: true, isDefault: true),
                AgentProvider(id: ProviderID(rawValue: "linter"), label: "Linter", command: ["l"], enabled: true, isDefault: false),
            ],
            stageProviderIds: ["lint": ProviderID(rawValue: "linter")])
        let ingestKey = AgentLauncher.stageKey(for: .ingest(sources: [emptySource], stateMarkdown: emptyState))
        #expect(ingestKey == "planner")
        // Ingest's resolved provider is the default (def), NOT the linter.
        #expect(config.provider(forStage: ingestKey).id == ProviderID(rawValue: "def"))
    }

    @Test func queryDoesNotRouteToLintStage() {
        // A one-shot query must NOT pick up the lint stage's pinned provider.
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: ProviderID(rawValue: "def"), label: "Def", command: ["d"], enabled: true, isDefault: true),
                AgentProvider(id: ProviderID(rawValue: "linter"), label: "Linter", command: ["l"], enabled: true, isDefault: false),
            ],
            stageProviderIds: ["lint": ProviderID(rawValue: "linter")])
        let queryKey = AgentLauncher.stageKey(for: .query(question: "Q", stateMarkdown: emptyState))
        #expect(queryKey == "chat")
        #expect(config.provider(forStage: queryKey).id == ProviderID(rawValue: "def"))
    }

    @Test func legacyLintStagePinStillResolves() {
        // The retired "lint" CONFIG key still resolves (legacy pins in
        // existing agent-providers.json files must not break), even though no
        // OperationRequest maps to it anymore.
        let config = AgentProvidersConfig(
            providers: [
                AgentProvider(id: ProviderID(rawValue: "def"), label: "Def", command: ["d"], enabled: true, isDefault: true),
                AgentProvider(id: ProviderID(rawValue: "linter"), label: "Linter", command: ["l"], enabled: true, isDefault: false),
            ],
            stageProviderIds: ["lint": ProviderID(rawValue: "linter")])
        #expect(config.provider(forStage: "lint").id == ProviderID(rawValue: "linter"))
    }
}
#endif // os(macOS)
