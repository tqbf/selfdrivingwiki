#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

enum ProfileBootFixture {
    static let listenerPluginID = PluginID("test.profile.store-listener")
    static let listenerEntryID = EntryID("store-listener")

    static func directory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func catalog(recorder: ProfileStoreEventRecorder? = nil) throws -> PluginCatalog {
        var definitions = fixtureDefinitions
        if let recorder {
            definitions.append(listenerDefinition(recorder: recorder))
        }
        return try PluginCatalog(definitions)
    }

    static func entries(databaseURL: URL, wikiID: String, includeAppProviders: Bool) -> [Entry] {
        var rows = [
            Entry(id: EntryID("store"), plugin: StorePlugin.id, config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string(wikiID),
            ]),
            Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id),
            Entry(id: EntryID("chats-persistence"), plugin: ChatsPersistencePlugin.id),
            Entry(id: EntryID("llm-runtime"), plugin: LlmRuntimePlugin.id),
            Entry(id: EntryID("tools"), plugin: ToolsPlugin.id),
            Entry(id: EntryID("system-prompt"), plugin: SystemPromptPlugin.id),
            Entry(id: EntryID("agent-loop"), plugin: AgentLoopPlugin.id),
            Entry(id: EntryID("extraction"), plugin: ExtractionPlugin.id),
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("renderers"), plugin: RenderersPlugin.id),
            Entry(id: EntryID("transport"), plugin: TransportPlugin.id),
            Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
            Entry(id: EntryID("no-op-tool"), plugin: NoOpToolPlugin.id),
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
        if includeAppProviders {
            rows.append(contentsOf: [
                Entry(id: EntryID("renderer-services"), plugin: RendererServicesPlugin.id),
                Entry(id: EntryID("daemon-transport"), plugin: DaemonTransportPlugin.id),
                Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
            ])
        }
        return rows
    }

    static func assertRequiredServices(in context: CordisContext) async throws {
        _ = try #require(try await context.find(StoreServiceKeys.store))
        _ = try #require(try await context.find(SessionServiceKeys.sessions))
        _ = try #require(try await context.find(ToolServiceKeys.tools))
        _ = try #require(try await context.find(PromptServiceKeys.systemPrompt))
        _ = try #require(try await context.find(SearchServiceKeys.providers))
        _ = try #require(try await context.find(RendererServiceKeys.renderers))
        _ = try #require(try await context.find(TransportServiceKeys.transport))
        _ = try #require(try await context.find(IntegrationServiceKeys.capabilities))
    }

    private static var fixtureDefinitions: [PluginDefinition] {
        [
            StorePlugin.definition,
            SessionsPlugin.definition,
            ChatsPersistencePlugin.definition,
            LlmRuntimePlugin.definition,
            ACPModelAdapterPlugin.definition(services: UnavailableAgentProviderServices()),
            ToolsPlugin.definition,
            NoOpToolPlugin.definition,
            SystemPromptPlugin.definition,
            AgentLoopPlugin.definition,
            ExtractionPlugin.definition,
            Pdf2mdExtractionPlugin.definition { ProfilePDFExtractor() },
            SearchPlugin.definition,
            EmbeddingsSearchPlugin.definition(
                configure: {},
                selectedIdentifier: { "fixture-embedding" },
                isAvailable: { false }),
            RenderersPlugin.definition,
            RendererServicesPlugin.definition { ProfileRendererServices() },
            TransportPlugin.definition,
            DaemonTransportPlugin.definition { fixtureTransportServices() },
            IntegrationsPlugin.definition,
            URLFetchIntegrationPlugin.definition { ProfileIntegrationEntryPoint() },
        ]
    }

    private static func listenerDefinition(recorder: ProfileStoreEventRecorder) -> PluginDefinition {
        PluginDefinition(
            id: listenerPluginID,
            dependencies: [ServiceDependency(StoreServiceKeys.store)]
        ) {
            try ComponentDefinition(
                label: listenerPluginID.rawValue,
                dependencies: [ServiceDependency(StoreServiceKeys.store)]
            ) { activation in
                let store = try await activation.require(StoreServiceKeys.store)
                _ = try await activation.on(StoreEventKeys.resourceChange) { event in
                    _ = try store.getPage(id: PageID(rawValue: event.id))
                    await recorder.append(event, observedCommittedState: true)
                }
            }
        }
    }
}

actor ProfileStoreEventRecorder {
    private(set) var events: [ResourceChangeEvent] = []
    private(set) var observedCommittedState = false

    func append(_ event: ResourceChangeEvent, observedCommittedState: Bool) {
        events.append(event)
        self.observedCommittedState = self.observedCommittedState || observedCommittedState
    }
}

private struct ProfilePDFExtractor: MarkdownExtractor {
    let displayName = "fixture"
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "fixture" }
}

private struct ProfileRendererServices: Sendable {}
private struct ProfileIntegrationEntryPoint: Sendable {}

private func fixtureTransportServices() -> DaemonTransportServices {
    DaemonTransportServices(
        startAdmission: {},
        acknowledge: { _ in },
        requestManualReconnect: {},
        events: { AsyncStream { $0.finish() } },
        availability: { .idle },
        stop: {})
}
#endif
