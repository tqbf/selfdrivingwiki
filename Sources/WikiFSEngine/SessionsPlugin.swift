import Cordis
import CordisLoader
import Foundation
import WikiFSCore

#if os(macOS)
public enum LauncherAdmissionPolicy {
    public static let laneLimits: [GenerationGate.GenerationLane: Int] = [.ingest: 1, .interactive: 3]
}

@MainActor
public struct LauncherPair {
    public let gate: GenerationGate
    public let launcher: AgentLauncher

    public init(gate: GenerationGate, launcher: AgentLauncher) {
        self.gate = gate
        self.launcher = launcher
    }
}

public struct LauncherFactory: Sendable {
    private let makePair: @MainActor @Sendable (WikiID) -> LauncherPair

    public init(makePair: @escaping @MainActor @Sendable (WikiID) -> LauncherPair) {
        self.makePair = makePair
    }

    @MainActor
    public func callAsFunction(wikiID: WikiID) -> LauncherPair {
        makePair(wikiID)
    }
}

public enum LauncherServiceKeys {
    public static let factory = ServiceKey<LauncherFactory>(label: "wiki.launcher-factory")
}

/// Sendable inputs for constructing one main-actor search owner outside Cordis.
/// The service value contains no UI model, runtime owner, or Cordis context.
public struct PerWikiSearchFactory: Sendable {
    public let identity: SearchRuntimeIdentity
    public let contentSource: any TantivyContentSource
    public let changeStreamFactory: any SearchChangeStreamFactory

    public init(
        identity: SearchRuntimeIdentity,
        contentSource: any TantivyContentSource,
        changeStreamFactory: any SearchChangeStreamFactory
    ) {
        self.identity = identity
        self.contentSource = contentSource
        self.changeStreamFactory = changeStreamFactory
    }

    @MainActor
    public func makeOwner(registry: SearchRuntimeRegistry) -> SearchCompositionOwner {
        SearchCompositionOwner(
            registry: registry,
            identity: identity,
            contentSource: contentSource,
            changeStreamFactory: changeStreamFactory)
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
        let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        var rawStore = try makeStore(databaseURL)
        let bus = rawStore.eventBus ?? WikiEventBus(wikiID: wikiID)
        rawStore.eventBus = bus
        let model = WikiStoreModel(store: rawStore)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            model.readService = WikiReadService(databaseURL: databaseURL)
        }
        let searchOwner = SearchCompositionOwner(
            registry: SearchRuntimeRegistry(),
            identity: SearchRuntimeIdentity(wikiID: wikiID, containerDirectory: containerDirectory),
            contentSource: StoreBackedTantivyContentSource(store: rawStore),
            changeStreamFactory: BusSearchChangeStreamFactory(bus: bus))
        model.searchServices = searchOwner.services
        searchOwner.start()
        let gate = GenerationGate(laneLimits: LauncherAdmissionPolicy.laneLimits)
        let launcher = AgentLauncher(
            generationGate: gate,
            extractionCoordinator: extractionCoordinator,
            providerServices: providerServices)
        launcher.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        launcher.onInteractiveUsage = interactiveUsageRecorder
        self.init(
            testFixtureWikiID: wikiID,
            descriptor: descriptor,
            store: model,
            searchCompositionOwner: searchOwner,
            generationGate: gate,
            agentLauncher: launcher,
            extractionCoordinator: extractionCoordinator,
            queueEngine: queueEngine,
            extractionProvider: extractionProvider,
            htmlMarkdownExtractor: htmlMarkdownExtractorFactory(),
            htmlBackend: htmlBackendResolver(),
            podcastBackend: podcastBackendResolver())
    }
}

@MainActor
extension AppProcessProfileOwner {
    /// Boots one child profile and constructs its main-actor session objects
    /// outside Cordis from resolved typed capabilities.
    public func bootWikiSession(
        wikiID: WikiID,
        descriptor: WikiDescriptor,
        containerDirectory: URL,
        catalog: PluginCatalog,
        extractionProvider: any QueueExtractionProvider,
        searchRuntimeRegistry: SearchRuntimeRegistry = SearchRuntimeRegistry(),
        pdf2mdScriptPathResolver: @escaping () -> String? = { nil },
        htmlMarkdownExtractorFactory: @escaping @MainActor () -> (any HtmlMarkdownExtractor)? = { nil },
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
        podcastBackendResolver: @escaping @MainActor () -> PodcastTranscriptionBackend? = { nil },
        interactiveUsageRecorder: @escaping (@MainActor (SessionUsage) -> Void) = { _ in }
    ) async throws -> ProfileWikiSession {
        let (lifetime, processServices) = try await readyComposition()
        let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        let childServices = try await lifetime.bootChild(
            wikiID: wikiID,
            catalog: catalog,
            layers: [PatchFile(entries: try ProductionProfiles.app(
                databaseURL: databaseURL, wikiID: wikiID, homeDirectory: containerDirectory))])
        let model = WikiStoreModel(store: childServices.store)
        model.readService = childServices.readService
        let searchOwner = childServices.searchFactory.makeOwner(registry: searchRuntimeRegistry)
        model.searchServices = searchOwner.services
        searchOwner.start()
        let pair = childServices.launcherFactory(wikiID: wikiID)
        pair.launcher.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        pair.launcher.onInteractiveUsage = interactiveUsageRecorder
        return ProfileWikiSession(
            wikiID: wikiID,
            descriptor: descriptor,
            store: model,
            searchCompositionOwner: searchOwner,
            generationGate: pair.gate,
            agentLauncher: pair.launcher,
            extractionCoordinator: ExtractionCoordinator(services: processServices.extraction),
            queueEngine: processServices.queue,
            extractionProvider: extractionProvider,
            htmlMarkdownExtractor: htmlMarkdownExtractorFactory(),
            htmlBackend: htmlBackendResolver(),
            podcastBackend: podcastBackendResolver(),
            profileLifetime: childServices.lifetime)
    }
}

public enum PerWikiRuntimeServiceKeys {
    public static let searchFactory = ServiceKey<PerWikiSearchFactory>(label: "wiki.search-factory")
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
                ServiceDependency(StoreServiceKeys.readService),
                ServiceDependency(ProcessServiceKeys.agentProvider),
                ServiceDependency(ProcessServiceKeys.extraction),
                ServiceDependency(AgentLoopServiceKeys.agentLoop),
            ],
            provisions: [
                ServiceDependency(PerWikiRuntimeServiceKeys.searchFactory),
                ServiceDependency(LauncherServiceKeys.factory),
            ],
            config: PerWikiRuntimeConfig.self
        ) { config in
            try ComponentDefinition(
                label: "wiki.runtime-services",
                dependencies: [
                    ServiceDependency(StoreServiceKeys.store),
                    ServiceDependency(StoreServiceKeys.readService),
                    ServiceDependency(ProcessServiceKeys.agentProvider),
                    ServiceDependency(ProcessServiceKeys.extraction),
                    ServiceDependency(AgentLoopServiceKeys.agentLoop),
                ],
                provisions: [
                    ServiceDependency(PerWikiRuntimeServiceKeys.searchFactory),
                    ServiceDependency(LauncherServiceKeys.factory),
                ]
            ) { activation in
                let store = try await activation.require(StoreServiceKeys.store)
                _ = try await activation.require(StoreServiceKeys.readService)
                let providerServices = try await activation.require(ProcessServiceKeys.agentProvider)
                let extractionServices = try await activation.require(ProcessServiceKeys.extraction)
                let agentLoopService = try await activation.require(AgentLoopServiceKeys.agentLoop)
                guard let eventBus = store.eventBus else {
                    throw PerWikiRuntimePluginError.missingEventBus
                }
                let wikiID = WikiID(rawValue: config.wikiID)
                let containerDirectory = URL(fileURLWithPath: config.containerDirectory, isDirectory: true)
                let launcherFactory = LauncherFactory { _ in
                    let gate = GenerationGate(laneLimits: LauncherAdmissionPolicy.laneLimits)
                    let launcher = AgentLauncher(
                        generationGate: gate,
                        extractionCoordinator: ExtractionCoordinator(services: extractionServices),
                        providerServices: providerServices,
                        agentLoopService: agentLoopService)
                    launcher.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
                    return LauncherPair(gate: gate, launcher: launcher)
                }
                let changeStreamFactory = await MainActor.run {
                    BusSearchChangeStreamFactory(bus: eventBus)
                }
                let searchFactory = PerWikiSearchFactory(
                    identity: SearchRuntimeIdentity(wikiID: wikiID, containerDirectory: containerDirectory),
                    contentSource: StoreBackedTantivyContentSource(store: store),
                    changeStreamFactory: changeStreamFactory)
                _ = try await activation.supply(PerWikiRuntimeServiceKeys.searchFactory, value: searchFactory)
                _ = try await activation.supply(LauncherServiceKeys.factory, value: launcherFactory)
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
