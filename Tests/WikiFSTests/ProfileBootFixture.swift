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

    static func appCatalog(recorder: ProfileStoreEventRecorder? = nil) throws -> PluginCatalog {
        let additionalDefinitions = recorder.map { [listenerDefinition(recorder: $0)] } ?? []
        return try AppPluginCatalog.build(
            factories: AppPluginCatalogFactories(
                base: baseFactories,
                makeRendererServices: { ProfileRendererServices() },
                makeDefuddleExtractor: { ProfileHTMLExtractor() },
                makeDaemonTransport: { fixtureTransportServices() },
                makeURLFetcher: { ProfileIntegrationEntryPoint() }),
            additionalDefinitions: additionalDefinitions)
    }

    static func daemonCatalog() throws -> PluginCatalog {
        try DaemonPluginCatalog.build(factories: DaemonPluginCatalogFactories(base: baseFactories))
    }

    static func processCatalog(includeAppServices: Bool, recorder: ProfileProcessDisposalRecorder) throws -> PluginCatalog {
        let queueFactory: ProcessPluginCatalogFactories.QueueFactory? = includeAppServices ? { @Sendable in
            let engine = try makeProfileQueueEngine()
            return ProcessRuntimeLease<any QueueEngineClient>(service: engine) {
                _ = await engine.shutdownForHandoff()
            }
        } : nil
        let transportFactory: ProcessPluginCatalogFactories.TransportFactory? = includeAppServices ? { @Sendable in
            let services = fixtureTransportServices()
            return ProcessRuntimeLease(service: services) { await services.stop() }
        } : nil
        let rendererFactory: ProcessPluginCatalogFactories.RendererFactory? = includeAppServices ? { @Sendable in
            ProcessRuntimeLease<any Sendable>(service: ProfileRendererServices()) { await recorder.record() }
        } : nil
        return try ProcessPluginCatalog.build(factories: ProcessPluginCatalogFactories(
            makeAgentProvider: {
                ProcessRuntimeLease(service: UnavailableAgentProviderServices()) { await recorder.record() }
            },
            makeExtraction: {
                ProcessRuntimeLease(service: UnavailableExtractionServices()) { await recorder.record() }
            },
            makeQueue: queueFactory,
            makeTransport: transportFactory,
            makeRenderer: rendererFactory))
    }

    static func processEntries(includeAppServices: Bool) throws -> [Entry] {
        try includeAppServices ? ProductionProfiles.appProcess() : ProductionProfiles.daemonProcess()
    }

    static func cliCatalog() throws -> PluginCatalog {
        try CLIPluginCatalog.build()
    }

    static func extractionProvider() -> any QueueExtractionProvider {
        ProfileQueueExtractionProvider()
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

    private static var baseFactories: BasePluginCatalogFactories {
        BasePluginCatalogFactories(
            agentProviderServices: UnavailableAgentProviderServices(),
            makePDFExtractor: { ProfilePDFExtractor() },
            configureEmbeddings: {},
            selectedEmbeddingIdentifier: { "fixture-embedding" },
            embeddingsAvailable: { false })
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

enum ProfileBootFailure: Error {
    case expected
}

actor ProfileBootGate {
    private var isOpen = false

    func wait() async {
        while !isOpen {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
    }
}

actor ProfileProcessDisposalRecorder {
    private(set) var count = 0
    func record() { count += 1 }
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

private struct ProfileHTMLExtractor: HtmlMarkdownExtractor {
    func extract(html: String) async -> HtmlExtractionResult? {
        HtmlExtractionResult(markdown: "fixture", title: nil)
    }
}

private struct ProfileRendererServices: Sendable {}
private struct ProfileIntegrationEntryPoint: Sendable {}

private func makeProfileQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let factory = QueueExtractionWorkerFactory(
        provider: ProfileQueueExtractionProvider(),
        emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}

private struct ProfileQueueExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? { nil }

    func persistExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        markdown: String,
        backend: ExtractionBackend,
        modelVersion: String?,
        technique: String?
    ) async throws {}
}

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
