#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Observation
import WikiFSCore

/// Assembly-independent factory signatures shared by extraction plugins and
/// the legacy extraction assembly while it remains during the migration.
public enum ExtractionPluginFactory {
    public typealias CredentialReader = @Sendable (ExtractionSecret) -> String?
    public typealias ACPResolver = @Sendable (ExtractionConfig) -> (any MarkdownExtractor)?
    public typealias LocalExtractor = @Sendable () async -> any MarkdownExtractor
}

/// One process-scoped service and the cleanup that owns its concrete runtime.
public struct ProcessRuntimeLease<Service: Sendable>: Sendable {
    public let service: Service
    public let dispose: @Sendable () async throws -> Void

    public init(service: Service, dispose: @escaping @Sendable () async throws -> Void) {
        self.service = service
        self.dispose = dispose
    }
}

public enum ProcessServiceKeys {
    public static let agentProvider = ServiceKey<any AgentProviderServices>(label: "process.agent-provider")
    public static let extraction = ServiceKey<any ExtractionServices>(label: "process.extraction")
    public static let queue = ServiceKey<any QueueEngineClient>(label: "process.queue")
    public static let transport = ServiceKey<DaemonTransportServices>(label: "process.transport")
    public static let renderer = ServiceKey<any Sendable>(label: "process.renderer")
}

public struct ProcessPluginCatalogFactories: Sendable {
    public typealias AgentProviderFactory = @Sendable () async throws -> ProcessRuntimeLease<any AgentProviderServices>
    public typealias ExtractionFactory = @Sendable () async throws -> ProcessRuntimeLease<any ExtractionServices>
    public typealias QueueFactory = @Sendable () async throws -> ProcessRuntimeLease<any QueueEngineClient>
    public typealias TransportFactory = @Sendable () async throws -> ProcessRuntimeLease<DaemonTransportServices>
    public typealias RendererFactory = @Sendable () async throws -> ProcessRuntimeLease<any Sendable>

    public let makeAgentProvider: AgentProviderFactory
    public let makeExtraction: ExtractionFactory
    public let makeQueue: QueueFactory?
    public let makeTransport: TransportFactory?
    public let makeRenderer: RendererFactory?

    public init(
        makeAgentProvider: @escaping AgentProviderFactory,
        makeExtraction: @escaping ExtractionFactory,
        makeQueue: QueueFactory? = nil,
        makeTransport: TransportFactory? = nil,
        makeRenderer: RendererFactory? = nil
    ) {
        self.makeAgentProvider = makeAgentProvider
        self.makeExtraction = makeExtraction
        self.makeQueue = makeQueue
        self.makeTransport = makeTransport
        self.makeRenderer = makeRenderer
    }
}

public struct BasePluginCatalogFactories: Sendable {
    public let agentProviderServices: any AgentProviderServices
    public let makePDFExtractor: ExtractionPluginFactory.LocalExtractor
    public let configureEmbeddings: EmbeddingsSearchProvider.Configure
    public let selectedEmbeddingIdentifier: EmbeddingsSearchProvider.SelectedIdentifier
    public let embeddingsAvailable: EmbeddingsSearchProvider.Availability

    public init(
        agentProviderServices: any AgentProviderServices,
        makePDFExtractor: @escaping ExtractionPluginFactory.LocalExtractor,
        configureEmbeddings: @escaping EmbeddingsSearchProvider.Configure = { await EmbeddingService.configure() },
        selectedEmbeddingIdentifier: @escaping EmbeddingsSearchProvider.SelectedIdentifier = { EmbeddingService.selectedEmbedderIdentifier() },
        embeddingsAvailable: @escaping EmbeddingsSearchProvider.Availability = { EmbeddingService.isAvailable }
    ) {
        self.agentProviderServices = agentProviderServices
        self.makePDFExtractor = makePDFExtractor
        self.configureEmbeddings = configureEmbeddings
        self.selectedEmbeddingIdentifier = selectedEmbeddingIdentifier
        self.embeddingsAvailable = embeddingsAvailable
    }
}

public struct AppPluginCatalogFactories: Sendable {
    public let base: BasePluginCatalogFactories
    public let makeRendererServices: RegisteredRendererProvider.Factory
    public let makeDefuddleExtractor: @Sendable () async -> any HtmlMarkdownExtractor
    public let makeDaemonTransport: RegisteredTransportProvider.Factory
    public let makeURLFetcher: RegisteredIntegrationCapability.Factory
    public let makeTantivyRuntime: SearchRuntimeFactory.Factory

    public init(
        base: BasePluginCatalogFactories,
        makeRendererServices: @escaping RegisteredRendererProvider.Factory,
        makeDefuddleExtractor: @escaping @Sendable () async -> any HtmlMarkdownExtractor,
        makeDaemonTransport: @escaping RegisteredTransportProvider.Factory,
        makeURLFetcher: @escaping RegisteredIntegrationCapability.Factory,
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeAssembly.runtimeFactory
    ) {
        self.base = base
        self.makeRendererServices = makeRendererServices
        self.makeDefuddleExtractor = makeDefuddleExtractor
        self.makeDaemonTransport = makeDaemonTransport
        self.makeURLFetcher = makeURLFetcher
        self.makeTantivyRuntime = makeTantivyRuntime
    }
}

public struct DaemonPluginCatalogFactories: Sendable {
    public let base: BasePluginCatalogFactories

    public init(base: BasePluginCatalogFactories) {
        self.base = base
    }
}

/// Typed process services resolved once from the app process profile.
public struct AppProcessRendererService: Sendable {
    public init() {}
}

public struct AppProcessServices: Sendable {
    public let agentProvider: any AgentProviderServices
    public let extraction: any ExtractionServices
    public let queue: any QueueEngineClient
    public let transport: DaemonTransportServices
    public let renderer: any Sendable

    public static func resolve(from profile: BootedProfile) async throws -> AppProcessServices {
        AppProcessServices(
            agentProvider: try await profile.context.require(ProcessServiceKeys.agentProvider),
            extraction: try await profile.context.require(ProcessServiceKeys.extraction),
            queue: try await profile.context.require(ProcessServiceKeys.queue),
            transport: try await profile.context.require(ProcessServiceKeys.transport),
            renderer: try await profile.context.require(ProcessServiceKeys.renderer))
    }
}

/// Owns asynchronous app process-profile startup and shutdown.
@MainActor
@Observable
public final class AppProcessProfileOwner {
    public enum Readiness: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public typealias Boot = @Sendable () async throws -> BootedProfile

    public private(set) var readiness: Readiness = .idle
    public private(set) var profile: BootedProfile?
    public private(set) var services: AppProcessServices?
    @ObservationIgnored private let boot: Boot
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownStarted = false

    public init(boot: @escaping Boot) {
        self.boot = boot
    }

    public convenience init(
        agentProvider: any AgentProviderServices,
        extraction: any ExtractionServices,
        queue: any QueueEngineClient,
        transport: DaemonTransportServices,
        renderer: any Sendable
    ) {
        self.init {
            let factories = ProcessPluginCatalogFactories(
                makeAgentProvider: { ProcessRuntimeLease(service: agentProvider) {} },
                makeExtraction: { ProcessRuntimeLease(service: extraction) {} },
                makeQueue: { ProcessRuntimeLease(service: queue) {} },
                makeTransport: { ProcessRuntimeLease(service: transport) {} },
                makeRenderer: { ProcessRuntimeLease(service: renderer) {} })
            return try await CordisBoot.boot(.init(
                catalog: try ProcessPluginCatalog.build(factories: factories),
                layers: [PatchFile(entries: ProductionProfileEntries.appProcess())]))
        }
    }

    public func start() {
        guard readiness == .idle, !shutdownStarted else { return }
        readiness = .loading
        startupTask = Task { [weak self, boot] in
            do {
                let profile = try await boot()
                let services = try await AppProcessServices.resolve(from: profile)
                guard let self, !Task.isCancelled, !self.shutdownStarted else {
                    try await profile.shutdown()
                    return
                }
                self.profile = profile
                self.services = services
                self.readiness = .ready
            } catch is CancellationError {
                // Shutdown owns cancellation and leaves the owner unavailable.
            } catch {
                guard let self, !self.shutdownStarted else { return }
                self.readiness = .failed(String(describing: error))
            }
        }
    }

    public func awaitSettled() async {
        await startupTask?.value
    }

    public func shutdown() async {
        guard !shutdownStarted else {
            await startupTask?.value
            return
        }
        shutdownStarted = true
        let task = startupTask
        task?.cancel()
        await task?.value
        startupTask = nil
        services = nil
        if let profile {
            do {
                try await profile.shutdown()
            } catch {
                DebugLog.store("App process profile shutdown failed: \(error)")
            }
        }
        profile = nil
    }
}

/// Typed process services resolved once from the daemon process profile.
public struct DaemonProcessServices: Sendable {
    public let agentProvider: any AgentProviderServices
    public let extraction: any ExtractionServices

    public static func resolve(from profile: BootedProfile) async throws -> DaemonProcessServices {
        DaemonProcessServices(
            agentProvider: try await profile.context.require(ProcessServiceKeys.agentProvider),
            extraction: try await profile.context.require(ProcessServiceKeys.extraction))
    }
}

/// Owns daemon process-profile startup and its retained per-wiki child profiles.
/// The actor owns every startup task and makes repeated shutdown requests safe.
public actor DaemonProcessProfileOwner {
    public typealias Boot = @Sendable () async throws -> BootedProfile
    public typealias BootWiki = @Sendable (WikiID, BootedProfile) async throws -> BootedProfile

    private let boot: Boot
    private let bootWiki: BootWiki
    private var startupTask: Task<(BootedProfile, DaemonProcessServices), Error>?
    private var process: (BootedProfile, DaemonProcessServices)?
    private var wikiTasks: [WikiID: Task<AppServices, Error>] = [:]
    private var wikiServices: [WikiID: AppServices] = [:]
    private var shutdownStarted = false

    public init(boot: @escaping Boot, bootWiki: @escaping BootWiki) {
        self.boot = boot
        self.bootWiki = bootWiki
    }

    public static func production(
        containerDirectory: URL,
        makeLocalExtractor: @escaping ExtractionPluginFactory.LocalExtractor
    ) throws -> DaemonProcessProfileOwner {
        let providerServices = MutableAgentProviderServices()
        let extractionCredentialStore = KeychainExtractionCredentialStore()
        let acpCredentialStore = KeychainACPCredentialStore()
        let processFactories = ProcessPluginCatalogFactories(
            makeAgentProvider: {
                let handle = try await AgentProviderRuntimeAssembly(
                    readConfiguration: { AgentProvidersConfig.loadOrSeed(from: containerDirectory) },
                    resolveCommand: { providers in
                        let searchPath = await PathPreflight.loginShellPATH()
                        return Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                            AgentLauncher.resolveCommand(for: provider, searchPath: searchPath)
                                .map { (provider.id, $0) }
                        })
                    },
                    readCredential: { providerID in
                        KeychainACPCredentialStore().apiKey(forProvider: providerID.rawValue)
                    },
                    resolvePermissionPolicy: { _ in .bypass })
                    .assemble()
                await providerServices.install(handle.services)
                return ProcessRuntimeLease(service: providerServices) { try await handle.dispose() }
            },
            makeExtraction: {
                let handle = try await ExtractionRuntimeAssembly(
                    readConfiguration: { ExtractionConfig.load(from: containerDirectory) },
                    readCredential: { extractionCredentialStore.secret($0) },
                    resolveACP: { configuration in
                        ACPExtractionClient.resolveProvider(
                            containerDirectory: containerDirectory,
                            acpProviderId: configuration.acpProviderId,
                            acpCredentialStore: acpCredentialStore)
                    },
                    httpFetcher: URLSessionRequestFetcher(),
                    makeLocalExtractor: makeLocalExtractor)
                    .assemble()
                return ProcessRuntimeLease(service: handle.services) { try await handle.dispose() }
            })
        let processCatalog = try ProcessPluginCatalog.build(factories: processFactories)
        let childCatalog = try DaemonPluginCatalog.build(factories: .init(base: .init(
            agentProviderServices: providerServices,
            makePDFExtractor: makeLocalExtractor)))
        return DaemonProcessProfileOwner(
            boot: {
                try await CordisBoot.boot(.init(
                    catalog: processCatalog,
                    layers: [PatchFile(entries: ProductionProfileEntries.daemonProcess())]))
            },
            bootWiki: { wikiID, processProfile in
                let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
                return try await CordisBoot.boot(.init(
                    catalog: childCatalog,
                    layers: [PatchFile(entries: ProductionProfileEntries.daemon(databaseURL: databaseURL, wikiID: wikiID))],
                    parent: processProfile.context))
            })
    }

    @discardableResult
    public func start() async throws -> DaemonProcessServices {
        if shutdownStarted { throw CancellationError() }
        if let process { return process.1 }
        if startupTask == nil {
            let boot = self.boot
            startupTask = Task {
                let profile = try await boot()
                do {
                    return (profile, try await DaemonProcessServices.resolve(from: profile))
                } catch {
                    do { try await profile.shutdown() } catch {
                        DebugLog.store("Daemon process profile cleanup after startup failure failed: \(error)")
                    }
                    throw error
                }
            }
        }
        guard let startupTask else { throw CancellationError() }
        let resolved = try await startupTask.value
        guard !shutdownStarted else {
            try await resolved.0.shutdown()
            throw CancellationError()
        }
        process = resolved
        return resolved.1
    }

    public func services() async throws -> DaemonProcessServices {
        try await start()
    }

    public func wiki(wikiID: WikiID) async throws -> AppServices {
        if let services = wikiServices[wikiID] { return services }
        let processProfile: BootedProfile
        if let process { processProfile = process.0 } else {
            _ = try await start()
            guard let process else { throw CancellationError() }
            processProfile = process.0
        }
        if wikiTasks[wikiID] == nil {
            let bootWiki = self.bootWiki
            wikiTasks[wikiID] = Task {
                let profile = try await bootWiki(wikiID, processProfile)
                do { return try await AppServices.resolve(from: profile) }
                catch {
                    do { try await profile.shutdown() } catch {
                        DebugLog.store("Daemon wiki profile cleanup after startup failure failed: \(error)")
                    }
                    throw error
                }
            }
        }
        guard let wikiTask = wikiTasks[wikiID] else { throw CancellationError() }
        let services = try await wikiTask.value
        guard !shutdownStarted else {
            try await services.shutdown()
            throw CancellationError()
        }
        wikiServices[wikiID] = services
        return services
    }

    public func removeWiki(_ wikiID: WikiID) async {
        wikiTasks[wikiID]?.cancel()
        if let task = wikiTasks.removeValue(forKey: wikiID) {
            do { _ = try await task.value } catch is CancellationError {
                // Removal intentionally cancels an unfinished child-profile boot.
            } catch {
                DebugLog.store("Daemon wiki profile task ended during removal: \(error)")
            }
        }
        if let services = wikiServices.removeValue(forKey: wikiID) {
            do { try await services.shutdown() } catch {
                DebugLog.store("Daemon wiki profile shutdown failed: \(error)")
            }
        }
    }

    public func shutdown() async {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        startupTask?.cancel()
        for task in wikiTasks.values { task.cancel() }
        for services in wikiServices.values {
            do { try await services.shutdown() } catch {
                DebugLog.store("Daemon wiki profile shutdown failed: \(error)")
            }
        }
        wikiServices.removeAll()
        wikiTasks.removeAll()
        if let profile = process?.0 {
            do { try await profile.shutdown() } catch {
                DebugLog.store("Daemon process profile shutdown failed: \(error)")
            }
        } else if let startupTask {
            do {
                let result = try await startupTask.value
                try await result.0.shutdown()
            } catch is CancellationError {
                // Shutdown intentionally cancels unfinished process-profile boot.
            } catch {
                DebugLog.store("Daemon process profile shutdown failed: \(error)")
            }
        }
        process = nil
        startupTask = nil
    }
}

/// Typed services resolved once from a booted profile. Consumers receive this
/// facade rather than a Cordis context or a legacy runtime assembly.
public struct AppServices: Sendable {
    public let profile: BootedProfile
    public let store: any WikiStore
    public let readPool: WikiReadPool
    public let extractionBackends: ExtractionBackendRegistry
    public let searchProviders: SearchProviderRegistry

    public static func resolve(from profile: BootedProfile) async throws -> AppServices {
        AppServices(
            profile: profile,
            store: try await profile.context.require(StoreServiceKeys.store),
            readPool: try await profile.context.require(StoreServiceKeys.readPool),
            extractionBackends: try await profile.context.require(ExtractionServiceKeys.backends),
            searchProviders: try await profile.context.require(SearchServiceKeys.providers))
    }

    public func shutdown() async throws {
        try await profile.shutdown()
    }
}

/// Observable per-wiki application facade built from one child profile and its
/// inherited process services. It mirrors `WikiSession` until callers migrate.
@MainActor
@Observable
public final class ProfileWikiSession: WikiSessionProtocol {
    public let profile: BootedProfile
    @ObservationIgnored private let session: WikiSession

    public var wikiID: WikiID { session.wikiID }
    public var descriptor: WikiDescriptor { session.descriptor }
    public var store: WikiStoreModel { session.store }
    public var agentLauncher: AgentLauncher { session.agentLauncher }
    public var extractionCoordinator: ExtractionCoordinator { session.extractionCoordinator }
    public var queueEngine: any QueueEngineClient { session.queueEngine }
    public var extractionProvider: any QueueExtractionProvider { session.extractionProvider }
    public var generationGate: GenerationGate { session.generationGate }
    public var searchServices: any SearchServices { session.searchServices }

    public var pendingBlobVacuum: BlobVacuumReport? {
        get { session.pendingBlobVacuum }
        set { session.pendingBlobVacuum = newValue }
    }

    public var pendingVacuumAll: VacuumReport? {
        get { session.pendingVacuumAll }
        set { session.pendingVacuumAll = newValue }
    }

    public var pendingWikiLink: (url: URL, openInNewTab: Bool)? {
        get { session.pendingWikiLink }
        set { session.pendingWikiLink = newValue }
    }

    public static func boot(
        wikiID: WikiID,
        descriptor: WikiDescriptor,
        containerDirectory: URL,
        catalog: PluginCatalog,
        processProfile: BootedProfile,
        processServices: AppProcessServices,
        extractionProvider: any QueueExtractionProvider,
        searchRuntimeRegistry: SearchRuntimeRegistry = SearchRuntimeRegistry(),
        pdf2mdScriptPathResolver: @escaping () -> String? = { nil },
        htmlMarkdownExtractorFactory: @escaping @MainActor () -> (any HtmlMarkdownExtractor)? = { nil },
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
        podcastBackendResolver: @escaping @MainActor () -> PodcastTranscriptionBackend? = { nil },
        interactiveUsageRecorder: @escaping (@MainActor (SessionUsage) -> Void) = { _ in }
    ) async throws -> ProfileWikiSession {
        let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        let profile = try await CordisBoot.boot(.init(
            catalog: catalog,
            layers: [PatchFile(entries: ProductionProfileEntries.app(databaseURL: databaseURL, wikiID: wikiID))],
            parent: processProfile.context))
        do {
            let childServices = try await AppServices.resolve(from: profile)
            return try ProfileWikiSession(
                wikiID: wikiID,
                descriptor: descriptor,
                containerDirectory: containerDirectory,
                childServices: childServices,
                processServices: processServices,
                extractionProvider: extractionProvider,
                searchRuntimeRegistry: searchRuntimeRegistry,
                pdf2mdScriptPathResolver: pdf2mdScriptPathResolver,
                htmlMarkdownExtractorFactory: htmlMarkdownExtractorFactory,
                htmlBackendResolver: htmlBackendResolver,
                podcastBackendResolver: podcastBackendResolver,
                interactiveUsageRecorder: interactiveUsageRecorder)
        } catch {
            do {
                try await profile.shutdown()
            } catch {
                DebugLog.store("Per-wiki profile cleanup after facade failure failed: \(error)")
            }
            throw error
        }
    }

    private init(
        wikiID: WikiID,
        descriptor: WikiDescriptor,
        containerDirectory: URL,
        childServices: AppServices,
        processServices: AppProcessServices,
        extractionProvider: any QueueExtractionProvider,
        searchRuntimeRegistry: SearchRuntimeRegistry,
        pdf2mdScriptPathResolver: @escaping () -> String?,
        htmlMarkdownExtractorFactory: @escaping @MainActor () -> (any HtmlMarkdownExtractor)?,
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend?,
        podcastBackendResolver: @escaping @MainActor () -> PodcastTranscriptionBackend?,
        interactiveUsageRecorder: @escaping (@MainActor (SessionUsage) -> Void)
    ) throws {
        profile = childServices.profile
        let coordinator = ExtractionCoordinator(services: processServices.extraction)
        let resolvedStore = childServices.store
        session = try WikiSession(
            wikiID: wikiID,
            descriptor: descriptor,
            containerDirectory: containerDirectory,
            extractionCoordinator: coordinator,
            queueEngine: processServices.queue,
            extractionProvider: extractionProvider,
            searchRuntimeRegistry: searchRuntimeRegistry,
            providerServices: processServices.agentProvider,
            makeStore: { _ in resolvedStore },
            pdf2mdScriptPathResolver: pdf2mdScriptPathResolver,
            htmlMarkdownExtractorFactory: htmlMarkdownExtractorFactory,
            htmlBackendResolver: htmlBackendResolver,
            podcastBackendResolver: podcastBackendResolver,
            interactiveUsageRecorder: interactiveUsageRecorder)
        session.store.readPool = childServices.readPool
    }

    public func updateDescriptor(_ descriptor: WikiDescriptor) { session.updateDescriptor(descriptor) }
    public func previewBlobVacuum() { session.previewBlobVacuum() }
    public func applyBlobVacuum() { session.applyBlobVacuum() }
    public func previewVacuumAll() { session.previewVacuumAll() }
    public func applyVacuumAll() { session.applyVacuumAll() }
    public func upgradeSearchIndex() async { await session.upgradeSearchIndex() }

    public func searchTantivy(
        query: String,
        kinds: [TantivyDocumentKind] = [],
        limit: Int = 20
    ) async -> [TantivyShadowSearchResult]? {
        await session.searchTantivy(query: query, kinds: kinds, limit: limit)
    }

    public func shutdown() async {
        await session.shutdownSearchRuntime()
        do {
            try await profile.shutdown()
        } catch {
            DebugLog.store("Per-wiki profile shutdown failed: \(error)")
        }
    }
}

/// Concrete per-wiki profile rows. The store row is a complete replacement for
/// the machine-independent placeholder shipped in `wikifs-base`.
public enum ProductionProfileEntries {
    public static func appProcess() -> [Entry] {
        [
            Entry(id: EntryID("process-agent-provider"), plugin: ProcessRuntimePlugins.agentProviderID),
            Entry(id: EntryID("process-extraction"), plugin: ProcessRuntimePlugins.extractionID),
            Entry(id: EntryID("process-queue"), plugin: ProcessRuntimePlugins.queueID),
            Entry(id: EntryID("process-transport"), plugin: ProcessRuntimePlugins.transportID),
            Entry(id: EntryID("process-renderer"), plugin: ProcessRuntimePlugins.rendererID),
        ]
    }

    public static func daemonProcess() -> [Entry] {
        [
            Entry(id: EntryID("process-agent-provider"), plugin: ProcessRuntimePlugins.agentProviderID),
            Entry(id: EntryID("process-extraction"), plugin: ProcessRuntimePlugins.extractionID),
        ]
    }

    public static func app(databaseURL: URL, wikiID: WikiID) -> [Entry] {
        base(databaseURL: databaseURL, wikiID: wikiID) + [
            Entry(id: EntryID("renderer-services"), plugin: RendererServicesPlugin.id),
            Entry(id: EntryID("daemon-transport"), plugin: DaemonTransportPlugin.id),
            Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
            Entry(id: EntryID("tantivy"), plugin: TantivySearchPlugin.id),
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
    }

    public static func daemon(databaseURL: URL, wikiID: WikiID) -> [Entry] {
        base(databaseURL: databaseURL, wikiID: wikiID) + [
            Entry(id: EntryID("embeddings"), plugin: EmbeddingsSearchPlugin.id),
        ]
    }

    public static func cli() -> [Entry] {
        [
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("tantivy"), plugin: TantivySearchPlugin.id),
        ]
    }

    private static func base(databaseURL: URL, wikiID: WikiID) -> [Entry] {
        [
            Entry(id: EntryID("store"), plugin: StorePlugin.id, config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string(wikiID.rawValue),
            ]),
            Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id),
            Entry(id: EntryID("chats-persistence"), plugin: ChatsPersistencePlugin.id),
            Entry(id: EntryID("llm-runtime"), plugin: LlmRuntimePlugin.id),
            Entry(id: EntryID("tools"), plugin: ToolsPlugin.id),
            Entry(id: EntryID("system-prompt"), plugin: SystemPromptPlugin.id),
            Entry(id: EntryID("agent-loop"), plugin: AgentLoopPlugin.id),
            Entry(id: EntryID("extraction"), plugin: ExtractionPlugin.id),
            Entry(id: EntryID("pdf2md"), plugin: Pdf2mdExtractionPlugin.id),
            Entry(id: EntryID("search"), plugin: SearchPlugin.id),
            Entry(id: EntryID("renderers"), plugin: RenderersPlugin.id),
            Entry(id: EntryID("transport"), plugin: TransportPlugin.id),
            Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
        ]
    }
}

public enum ProcessRuntimePlugins {
    public static let agentProviderID = PluginID("process.agent-provider")
    public static let extractionID = PluginID("process.extraction")
    public static let queueID = PluginID("process.queue")
    public static let transportID = PluginID("process.transport")
    public static let rendererID = PluginID("process.renderer")

    public static func definitions(_ factories: ProcessPluginCatalogFactories) -> [PluginDefinition] {
        var definitions = [
            definition(id: agentProviderID, key: ProcessServiceKeys.agentProvider, factory: factories.makeAgentProvider),
            definition(id: extractionID, key: ProcessServiceKeys.extraction, factory: factories.makeExtraction),
        ]
        if let factory = factories.makeQueue {
            definitions.append(definition(id: queueID, key: ProcessServiceKeys.queue, factory: factory))
        }
        if let factory = factories.makeTransport {
            definitions.append(definition(id: transportID, key: ProcessServiceKeys.transport, factory: factory))
        }
        if let factory = factories.makeRenderer {
            definitions.append(definition(id: rendererID, key: ProcessServiceKeys.renderer, factory: factory))
        }
        return definitions
    }

    private static func definition<Service: Sendable>(
        id: PluginID,
        key: ServiceKey<Service>,
        factory: @escaping @Sendable () async throws -> ProcessRuntimeLease<Service>
    ) -> PluginDefinition {
        PluginDefinition(id: id, provisions: [ServiceDependency(key)]) {
            try ComponentDefinition(
                label: id.rawValue,
                provisions: [ServiceDependency(key)]) { activation in
                    let lease = try await factory()
                    _ = try await activation.supply(key, value: lease.service)
                    _ = try await activation.effect { _ in try await lease.dispose() }
                }
        }
    }
}

public enum ProcessPluginCatalog {
    public static func build(factories: ProcessPluginCatalogFactories) throws -> PluginCatalog {
        try PluginCatalog(ProcessRuntimePlugins.definitions(factories))
    }
}

public enum AppPluginCatalog {
    public static func build(
        factories: AppPluginCatalogFactories,
        additionalDefinitions: [PluginDefinition] = []
    ) throws -> PluginCatalog {
        var definitions = baseDefinitions(factories.base)
        definitions.append(contentsOf: [
            DefuddleExtractionPlugin.definition(makeExtractor: factories.makeDefuddleExtractor),
            RendererServicesPlugin.definition(makeServices: factories.makeRendererServices),
            DaemonTransportPlugin.definition(makeServices: factories.makeDaemonTransport),
            URLFetchIntegrationPlugin.definition(makeFetcher: factories.makeURLFetcher),
        ])
        definitions.append(TantivySearchPlugin.definition(makeRuntime: factories.makeTantivyRuntime))
        definitions.append(contentsOf: additionalDefinitions)
        return try PluginCatalog(definitions)
    }
}

public enum DaemonPluginCatalog {
    public static func build(
        factories: DaemonPluginCatalogFactories,
        additionalDefinitions: [PluginDefinition] = []
    ) throws -> PluginCatalog {
        try PluginCatalog(baseDefinitions(factories.base) + additionalDefinitions)
    }
}

public enum CLIPluginCatalog {
    public static func build(
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeAssembly.runtimeFactory
    ) throws -> PluginCatalog {
        try PluginCatalog([
            SearchPlugin.definition,
            TantivySearchPlugin.definition(makeRuntime: makeTantivyRuntime),
        ])
    }
}

private func baseDefinitions(_ factories: BasePluginCatalogFactories) -> [PluginDefinition] {
    [
        StorePlugin.definition,
        SessionsPlugin.definition,
        ChatsPersistencePlugin.definition,
        LlmRuntimePlugin.definition,
        ACPModelAdapterPlugin.definition(services: factories.agentProviderServices),
        ToolsPlugin.definition,
        NoOpToolPlugin.definition,
        SystemPromptPlugin.definition,
        AgentLoopPlugin.definition,
        ExtractionPlugin.definition,
        Pdf2mdExtractionPlugin.definition(makeExtractor: factories.makePDFExtractor),
        SearchPlugin.definition,
        EmbeddingsSearchPlugin.definition(
            configure: factories.configureEmbeddings,
            selectedIdentifier: factories.selectedEmbeddingIdentifier,
            isAvailable: factories.embeddingsAvailable),
        RenderersPlugin.definition,
        TransportPlugin.definition,
        IntegrationsPlugin.definition,
    ]
}
#endif
