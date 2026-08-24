import Cordis
import Foundation
import WikiFSCore

#if os(macOS)
/// Every stored reference is created and accessed on `MainActor`; the unchecked
/// conformance only permits Cordis to carry the opaque bundle between actors.
@MainActor
// swiftlint:disable:next unchecked_sendable
public struct PerWikiRuntimeServices: @unchecked Sendable {
    public let model: WikiStoreModel
    public let searchOwner: SearchCompositionOwner
    public let generationGate: GenerationGate
    public let agentLauncher: AgentLauncher

    public var searchServices: any SearchServices { searchOwner.services }
}

@MainActor
extension PerWikiRuntimeServices {
    public static func testFixture(
        wikiID: WikiID,
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        providerServices: any AgentProviderServices = UnavailableAgentProviderServices(),
        makeStore: (URL) throws -> any WikiStore = { try StoreBackend.current.makeStore(databaseURL: $0) }
    ) throws -> PerWikiRuntimeServices {
        let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        var store = try makeStore(databaseURL)
        let bus = store.eventBus ?? WikiEventBus(wikiID: wikiID)
        store.eventBus = bus
        let model = WikiStoreModel(store: store)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            model.readPool = WikiReadPool(databaseURL: databaseURL)
        }
        let searchOwner = SearchCompositionOwner(
            registry: SearchRuntimeRegistry(),
            identity: SearchRuntimeIdentity(wikiID: wikiID, containerDirectory: containerDirectory),
            contentSource: StoreBackedTantivyContentSource(store: store),
            changeStreamFactory: BusSearchChangeStreamFactory(bus: bus))
        model.searchServices = searchOwner.services
        searchOwner.start()
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
        return PerWikiRuntimeServices(
            model: model,
            searchOwner: searchOwner,
            generationGate: gate,
            agentLauncher: AgentLauncher(
                generationGate: gate,
                extractionCoordinator: extractionCoordinator,
                providerServices: providerServices))
    }
}

@MainActor
extension ProfileWikiSession {
    /// Test-fixture compatibility only. Production sessions must use `boot(...)`.
    public convenience init(
        testFixtureWikiID wikiID: WikiID,
        descriptor: WikiDescriptor,
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: any QueueEngineClient,
        extractionProvider: any QueueExtractionProvider,
        providerServices: any AgentProviderServices = UnavailableAgentProviderServices(),
        makeStore: (URL) throws -> any WikiStore = { try StoreBackend.current.makeStore(databaseURL: $0) },
        pdf2mdScriptPathResolver: @escaping () -> String? = { nil },
        htmlMarkdownExtractorFactory: @escaping @MainActor () -> (any HtmlMarkdownExtractor)? = { nil },
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
        podcastBackendResolver: @escaping @MainActor () -> PodcastTranscriptionBackend? = { nil },
        interactiveUsageRecorder: @escaping @MainActor (SessionUsage) -> Void = { _ in }
    ) throws {
        let runtime = try PerWikiRuntimeServices.testFixture(
            wikiID: wikiID,
            containerDirectory: containerDirectory,
            extractionCoordinator: extractionCoordinator,
            providerServices: providerServices,
            makeStore: makeStore)
        runtime.agentLauncher.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        runtime.agentLauncher.onInteractiveUsage = interactiveUsageRecorder
        self.init(
            wikiID: wikiID,
            descriptor: descriptor,
            runtime: runtime,
            extractionCoordinator: extractionCoordinator,
            queueEngine: queueEngine,
            extractionProvider: extractionProvider,
            htmlMarkdownExtractor: htmlMarkdownExtractorFactory(),
            htmlBackend: htmlBackendResolver(),
            podcastBackend: podcastBackendResolver())
    }
}

public enum PerWikiRuntimeServiceKeys {
    public static let services = ServiceKey<PerWikiRuntimeServices>(label: "wiki.runtime-services")
}

public struct PerWikiRuntimeConfig: PluginConfig, Equatable {
    public let wikiID: String
    public let containerDirectory: String

    public init(wikiID: String, containerDirectory: String) {
        self.wikiID = wikiID
        self.containerDirectory = containerDirectory
    }

    public static func validate(_ config: PerWikiRuntimeConfig) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check("wikiID", !config.wikiID.isEmpty, "wiki id must not be empty")
        validation.check("containerDirectory", !config.containerDirectory.isEmpty, "container directory must not be empty")
        return validation.allIssues
    }
}

public enum PerWikiRuntimePluginError: Error, Equatable {
    case missingEventBus
}

public enum PerWikiRuntimePlugin {
    public static let id = PluginID("wiki.runtime-services")

    public static let definition = makeDefinition()

    private static func makeDefinition() -> PluginDefinition {
        PluginDefinition(
            id: id,
            dependencies: [
                ServiceDependency(StoreServiceKeys.store),
                ServiceDependency(StoreServiceKeys.readPool),
                ServiceDependency(ProcessServiceKeys.agentProvider),
                ServiceDependency(ProcessServiceKeys.extraction),
            ],
            provisions: [ServiceDependency(PerWikiRuntimeServiceKeys.services)],
            config: PerWikiRuntimeConfig.self
        ) { config in
            try ComponentDefinition(
                label: "wiki.runtime-services",
                dependencies: [
                    ServiceDependency(StoreServiceKeys.store),
                    ServiceDependency(StoreServiceKeys.readPool),
                    ServiceDependency(ProcessServiceKeys.agentProvider),
                    ServiceDependency(ProcessServiceKeys.extraction),
                ],
                provisions: [ServiceDependency(PerWikiRuntimeServiceKeys.services)]
            ) { activation in
                let store = try await activation.require(StoreServiceKeys.store)
                let readPool = try await activation.require(StoreServiceKeys.readPool)
                let providerServices = try await activation.require(ProcessServiceKeys.agentProvider)
                let extractionServices = try await activation.require(ProcessServiceKeys.extraction)
                guard let eventBus = store.eventBus else {
                    throw PerWikiRuntimePluginError.missingEventBus
                }
                let wikiID = WikiID(rawValue: config.wikiID)
                let containerDirectory = URL(fileURLWithPath: config.containerDirectory, isDirectory: true)
                let services = await MainActor.run {
                    let model = WikiStoreModel(store: store)
                    model.readPool = readPool
                    let searchOwner = SearchCompositionOwner(
                        registry: SearchRuntimeRegistry(),
                        identity: SearchRuntimeIdentity(wikiID: wikiID, containerDirectory: containerDirectory),
                        contentSource: StoreBackedTantivyContentSource(store: store),
                        changeStreamFactory: BusSearchChangeStreamFactory(bus: eventBus))
                    model.searchServices = searchOwner.services
                    searchOwner.start()
                    let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
                    let launcher = AgentLauncher(
                        generationGate: gate,
                        extractionCoordinator: ExtractionCoordinator(services: extractionServices),
                        providerServices: providerServices)
                    return PerWikiRuntimeServices(
                        model: model,
                        searchOwner: searchOwner,
                        generationGate: gate,
                        agentLauncher: launcher)
                }
                _ = try await activation.effect { _ in await services.searchOwner.shutdown() }
                _ = try await activation.supply(PerWikiRuntimeServiceKeys.services, value: services)
            }
        }
    }
}
#endif

public enum SessionsPlugin {
    public static let id = PluginID("wiki.sessions")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki sessions",
        dependencies: [ServiceDependency(StoreServiceKeys.store)],
        provisions: [ServiceDependency(SessionServiceKeys.sessions)]
    ) {
        try ComponentDefinition(
            label: "wiki.sessions",
            dependencies: [ServiceDependency(StoreServiceKeys.store)],
            provisions: [ServiceDependency(SessionServiceKeys.sessions)]
        ) { activation in
            _ = try await activation.require(StoreServiceKeys.store)
            let service = SessionLogService { batch in
                await activation.emit(SessionEventKeys.appended, batch)
            }
            _ = try await activation.supply(SessionServiceKeys.sessions, value: service)
        }
    }
}

public enum ChatsPersistencePlugin {
    public static let id = PluginID("wiki.chats-persistence")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki chat persistence",
        dependencies: [ServiceDependency(StoreServiceKeys.store)]
    ) {
        try ComponentDefinition(
            label: "wiki.chats-persistence",
            dependencies: [ServiceDependency(StoreServiceKeys.store)]
        ) { activation in
            let store = try await activation.require(StoreServiceKeys.store)
            _ = try await activation.on(SessionEventKeys.appended) { batch in
                let persistable = batch.events.filter(\.isPersistable)
                guard !persistable.isEmpty else { return }
                try store.appendChatMessages(chatID: batch.chatID, events: persistable)
            }
        }
    }
}
