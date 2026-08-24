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
    public static let renderer = ServiceKey<any RendererServices>(label: "process.renderer")
    public static let embeddings = ServiceKey<EmbeddingsSearchProvider>(label: "process.embeddings")
    public static let urlFetchProvider = ServiceKey<URLFetchProvider>(label: "process.integration.url-fetch-provider")
    public static let zoteroClientProvider = ServiceKey<ZoteroClientProvider>(label: "process.integration.zotero-client-provider")
}

public struct ProcessPluginCatalogFactories: Sendable {
    public typealias AgentProviderFactory = @Sendable () async throws -> ProcessRuntimeLease<any AgentProviderServices>
    public typealias ExtractionFactory = @Sendable () async throws -> ProcessRuntimeLease<any ExtractionServices>
    public typealias QueueFactory = @Sendable () async throws -> ProcessRuntimeLease<any QueueEngineClient>
    public typealias TransportFactory = @Sendable () async throws -> ProcessRuntimeLease<DaemonTransportServices>
    public typealias RendererFactory = @Sendable () async throws -> ProcessRuntimeLease<any RendererServices>
    public typealias EmbeddingsFactory = @Sendable () async throws -> ProcessRuntimeLease<EmbeddingsSearchProvider>
    public typealias URLFetchProviderFactory = @Sendable () async throws -> ProcessRuntimeLease<URLFetchProvider>
    public typealias ZoteroClientProviderFactory = @Sendable () async throws -> ProcessRuntimeLease<ZoteroClientProvider>

    public let makeAgentProvider: AgentProviderFactory
    public let makeExtraction: ExtractionFactory
    public let makeQueue: QueueFactory?
    public let makeTransport: TransportFactory?
    public let makeRenderer: RendererFactory?
    public let makeEmbeddings: EmbeddingsFactory
    public let makeURLFetchProvider: URLFetchProviderFactory?
    public let makeZoteroClientProvider: ZoteroClientProviderFactory?

    public init(
        makeAgentProvider: @escaping AgentProviderFactory,
        makeExtraction: @escaping ExtractionFactory,
        makeQueue: QueueFactory? = nil,
        makeTransport: TransportFactory? = nil,
        makeRenderer: RendererFactory? = nil,
        makeEmbeddings: @escaping EmbeddingsFactory,
        makeURLFetchProvider: URLFetchProviderFactory? = nil,
        makeZoteroClientProvider: ZoteroClientProviderFactory? = nil
    ) {
        self.makeAgentProvider = makeAgentProvider
        self.makeExtraction = makeExtraction
        self.makeQueue = makeQueue
        self.makeTransport = makeTransport
        self.makeRenderer = makeRenderer
        self.makeEmbeddings = makeEmbeddings
        self.makeURLFetchProvider = makeURLFetchProvider
        self.makeZoteroClientProvider = makeZoteroClientProvider
    }
}

public struct BasePluginCatalogFactories: Sendable {
    public let agentProviderServices: any AgentProviderServices
    public let makePDFExtractor: ExtractionPluginFactory.LocalExtractor

    public init(
        agentProviderServices: any AgentProviderServices,
        makePDFExtractor: @escaping ExtractionPluginFactory.LocalExtractor
    ) {
        self.agentProviderServices = agentProviderServices
        self.makePDFExtractor = makePDFExtractor
    }
}

public struct AppPluginCatalogFactories: Sendable {
    public let base: BasePluginCatalogFactories
    public let makeDefuddleExtractor: @Sendable () async -> any HtmlMarkdownExtractor
    public let makeDaemonTransport: RegisteredTransportProvider.Factory
    public let makeTantivyRuntime: SearchRuntimeFactory.Factory

    public init(
        base: BasePluginCatalogFactories,
        makeDefuddleExtractor: @escaping @Sendable () async -> any HtmlMarkdownExtractor,
        makeDaemonTransport: @escaping RegisteredTransportProvider.Factory,
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeCompositionFactory.runtimeFactory
    ) {
        self.base = base
        self.makeDefuddleExtractor = makeDefuddleExtractor
        self.makeDaemonTransport = makeDaemonTransport
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
public struct AppProcessServices: Sendable {
    public let agentProvider: any AgentProviderServices
    public let extraction: any ExtractionServices
    public let queue: any QueueEngineClient
    public let transport: DaemonTransportServices
    public let renderer: any RendererServices

    public static func resolve(from profile: BootedProfile) async throws -> AppProcessServices {
        AppProcessServices(
            agentProvider: try await profile.context.require(ProcessServiceKeys.agentProvider),
            extraction: try await profile.context.require(ProcessServiceKeys.extraction),
            queue: try await profile.context.require(ProcessServiceKeys.queue),
            transport: try await profile.context.require(ProcessServiceKeys.transport),
            renderer: try await profile.context.require(ProcessServiceKeys.renderer))
    }
}

public enum ProfileLifetimeError: Error, Equatable, Sendable {
    case shutdownStarted
}

/// Opaque, idempotent ownership of one booted Cordis profile.
/// Normal application code can shut the profile down but cannot access its context.
public actor ProfileLifetime {
    private var profile: BootedProfile?
    private var shutdownStarted = false

    internal init(profile: BootedProfile) {
        self.profile = profile
    }

    internal func bootChild(
        catalog: PluginCatalog,
        layers: [PatchFile]
    ) async throws -> AppServices {
        guard !shutdownStarted, let profile else {
            throw ProfileLifetimeError.shutdownStarted
        }
        let child = try await CordisBoot.boot(.init(
            catalog: catalog,
            layers: layers,
            parent: profile.context))
        guard !shutdownStarted else {
            try await child.shutdown()
            throw ProfileLifetimeError.shutdownStarted
        }
        do {
            return try await AppServices.resolve(from: child)
        } catch {
            do { try await child.shutdown() } catch let cleanupError {
                DebugLog.store("Child profile cleanup after resolution failure failed: \(cleanupError)")
            }
            throw error
        }
    }

    public func shutdown() async throws {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        let ownedProfile = profile
        profile = nil
        try await ownedProfile?.shutdown()
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
    public private(set) var services: AppProcessServices?
    @ObservationIgnored private var lifetime: ProfileLifetime?
    @ObservationIgnored private let boot: Boot
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownStarted = false

    public init(boot: @escaping Boot) {
        self.boot = boot
    }

    public convenience init(factories: ProcessPluginCatalogFactories, homeDirectory: URL? = nil) {
        self.init {
            try await CordisBoot.boot(.init(
                catalog: try ProcessPluginCatalog.build(factories: factories),
                layers: [PatchFile(entries: try ProductionProfiles.appProcess(homeDirectory: homeDirectory))]))
        }
    }

    public convenience init(
        agentProvider: any AgentProviderServices,
        extraction: any ExtractionServices,
        queue: any QueueEngineClient,
        transport: DaemonTransportServices,
        renderer: any RendererServices
    ) {
        self.init(factories: ProcessPluginCatalogFactories(
            makeAgentProvider: { ProcessRuntimeLease(service: agentProvider) {} },
            makeExtraction: { ProcessRuntimeLease(service: extraction) {} },
            makeQueue: { ProcessRuntimeLease(service: queue) {} },
            makeTransport: { ProcessRuntimeLease(service: transport) {} },
            makeRenderer: { ProcessRuntimeLease(service: renderer) {} },
            makeEmbeddings: {
                ProcessRuntimeLease(service: .unavailable(identifier: "unavailable-fixture"), dispose: {})
            }))
    }

    public func start() {
        guard readiness == .idle, !shutdownStarted else { return }
        readiness = .loading
        startupTask = Task { [weak self, boot] in
            do {
                let profile = try await boot()
                let services: AppProcessServices
                do {
                    services = try await AppProcessServices.resolve(from: profile)
                } catch {
                    do { try await profile.shutdown() } catch {
                        DebugLog.store("App process profile cleanup after resolution failure failed: \(error)")
                    }
                    throw error
                }
                guard let self, !Task.isCancelled, !self.shutdownStarted else {
                    try await profile.shutdown()
                    return
                }
                self.lifetime = ProfileLifetime(profile: profile)
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

    internal func readyComposition() async throws -> (ProfileLifetime, AppProcessServices) {
        await awaitSettled()
        guard let lifetime, let services else {
            throw SessionLoadingError.processProfileUnavailable("app process profile is not ready: \(readiness)")
        }
        return (lifetime, services)
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
        if let lifetime {
            do {
                try await lifetime.shutdown()
            } catch {
                DebugLog.store("App process profile shutdown failed: \(error)")
            }
        }
        lifetime = nil
    }
}

/// Typed process services resolved once from the daemon process profile.
public struct DaemonProcessServices: Sendable {
    public let agentProvider: any AgentProviderServices
    public let extraction: any ExtractionServices
    public let tools: ToolRuntime?

    public static func resolve(from profile: BootedProfile) async throws -> DaemonProcessServices {
        DaemonProcessServices(
            agentProvider: try await profile.context.require(ProcessServiceKeys.agentProvider),
            extraction: try await profile.context.require(ProcessServiceKeys.extraction),
            tools: try await profile.context.find(ToolServiceKeys.tools))
    }
}

/// Owns daemon process-profile startup and its retained per-wiki child profiles.
/// The actor owns every startup task and makes repeated shutdown requests safe.
public actor DaemonProcessProfileOwner {
    public typealias Boot = @Sendable () async throws -> BootedProfile
    public typealias BootWiki = @Sendable (WikiID, BootedProfile) async throws -> BootedProfile

    private let boot: Boot
    private let bootWiki: BootWiki
    private struct WikiLifecycle: Sendable {
        let task: Task<AppServices, Error>
        var services: AppServices?
    }

    private var startupTask: Task<(BootedProfile, DaemonProcessServices), Error>?
    private var process: (BootedProfile, DaemonProcessServices)?
    private var wikis: [WikiID: WikiLifecycle] = [:]
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
                let handle = try await AgentProviderRuntimeFactory(
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
                let handle = try await ExtractionRuntimeFactory(
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
            },
            makeEmbeddings: {
                ProcessRuntimeLease(
                    service: .unavailable(identifier: "unavailable-daemon"),
                    dispose: {})
            })
        let processCatalog = try ProcessPluginCatalog.build(factories: processFactories)
        let childCatalog = try DaemonPluginCatalog.build(factories: .init(base: .init(
            agentProviderServices: providerServices,
            makePDFExtractor: makeLocalExtractor)))
        return DaemonProcessProfileOwner(
            boot: {
                try await CordisBoot.boot(.init(
                    catalog: processCatalog,
                    layers: [PatchFile(entries: try ProductionProfiles.daemonProcess(homeDirectory: containerDirectory))]))
            },
            bootWiki: { wikiID, processProfile in
                let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
                return try await CordisBoot.boot(.init(
                    catalog: childCatalog,
                    layers: [PatchFile(entries: try ProductionProfiles.daemon(
                        databaseURL: databaseURL, wikiID: wikiID, homeDirectory: containerDirectory))],
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
        if let services = wikis[wikiID]?.services { return services }
        let processProfile: BootedProfile
        if let process { processProfile = process.0 } else {
            _ = try await start()
            guard let process else { throw CancellationError() }
            processProfile = process.0
        }
        if wikis[wikiID] == nil {
            let bootWiki = self.bootWiki
            let task = Task {
                let profile = try await bootWiki(wikiID, processProfile)
                do { return try await AppServices.resolve(from: profile) }
                catch {
                    do { try await profile.shutdown() } catch {
                        DebugLog.store("Daemon wiki profile cleanup after startup failure failed: \(error)")
                    }
                    throw error
                }
            }
            wikis[wikiID] = WikiLifecycle(task: task, services: nil)
        }
        guard let task = wikis[wikiID]?.task else { throw CancellationError() }
        let services = try await task.value
        guard !shutdownStarted, wikis[wikiID]?.task == task else {
            try await services.shutdown()
            throw CancellationError()
        }
        wikis[wikiID]?.services = services
        return services
    }

    public func removeWiki(_ wikiID: WikiID) async {
        guard let lifecycle = wikis.removeValue(forKey: wikiID) else { return }
        lifecycle.task.cancel()
        let services: AppServices?
        do { services = try await lifecycle.task.value }
        catch is CancellationError {
            // Removal intentionally cancels an unfinished child-profile boot.
            services = lifecycle.services
        } catch {
            DebugLog.store("Daemon wiki profile task ended during removal: \(error)")
            services = lifecycle.services
        }
        if let services {
            do { try await services.shutdown() } catch {
                DebugLog.store("Daemon wiki profile shutdown failed: \(error)")
            }
        }
    }

    public func shutdown() async {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        startupTask?.cancel()
        let lifecycles = Array(wikis.values)
        wikis.removeAll()
        for lifecycle in lifecycles { lifecycle.task.cancel() }
        for lifecycle in lifecycles {
            let services: AppServices?
            do { services = try await lifecycle.task.value }
            catch is CancellationError { services = lifecycle.services }
            catch {
                DebugLog.store("Daemon wiki profile task ended during shutdown: \(error)")
                services = lifecycle.services
            }
            if let services {
                do { try await services.shutdown() } catch {
                    DebugLog.store("Daemon wiki profile shutdown failed: \(error)")
                }
            }
        }
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
    public let lifetime: ProfileLifetime
    public let store: any WikiStore
    public let readService: WikiReadService
    public let extractionBackends: ExtractionBackendRegistry
    public let searchProviders: SearchProviderRegistry
    public let launcherFactory: LauncherFactory
    public let searchFactory: PerWikiSearchFactory

    internal static func resolve(from profile: BootedProfile) async throws -> AppServices {
        AppServices(
            lifetime: ProfileLifetime(profile: profile),
            store: try await profile.context.require(StoreServiceKeys.store),
            readService: try await profile.context.require(StoreServiceKeys.readService),
            extractionBackends: try await profile.context.require(ExtractionServiceKeys.backends),
            searchProviders: try await profile.context.require(SearchServiceKeys.providers),
            launcherFactory: try await profile.context.require(LauncherServiceKeys.factory),
            searchFactory: try await profile.context.require(PerWikiRuntimeServiceKeys.searchFactory))
    }

    public func shutdown() async throws {
        try await lifetime.shutdown()
    }
}

/// Production composition loaded from the shipped YAML bundles. Catalogs still
/// provide injected factories; only machine facts are generated in Swift.
public enum ProductionProfiles {
    public static func appProcess(homeDirectory: URL? = nil) throws -> [Entry] {
        try resolve(kind: .app, scope: .process, homeDirectory: homeDirectory).entries
    }

    public static func daemonProcess(homeDirectory: URL? = nil) throws -> [Entry] {
        try resolve(kind: .daemon, scope: .process, homeDirectory: homeDirectory).entries
    }

    public static func app(databaseURL: URL, wikiID: WikiID, homeDirectory: URL? = nil) throws -> [Entry] {
        try resolve(
            kind: .app, scope: .wiki, homeDirectory: homeDirectory,
            ambient: ambient(databaseURL: databaseURL, wikiID: wikiID)).entries
    }

    public static func daemon(databaseURL: URL, wikiID: WikiID, homeDirectory: URL? = nil) throws -> [Entry] {
        try resolve(
            kind: .daemon, scope: .wiki, homeDirectory: homeDirectory,
            ambient: ambient(databaseURL: databaseURL, wikiID: wikiID)).entries
    }

    public static func cli(homeDirectory: URL? = nil, overlay: String? = nil) throws -> [Entry] {
        try resolve(kind: .cli, scope: .process, homeDirectory: homeDirectory, overlay: overlay).entries
    }

    public static func cli(
        databaseURL: URL,
        wikiID: WikiID,
        homeDirectory: URL,
        overlay: String? = nil
    ) throws -> [Entry] {
        try resolve(
            kind: .cli,
            scope: .process,
            homeDirectory: homeDirectory,
            overlay: overlay,
            ambient: PatchFile(entries: [
                Entry(id: EntryID("store"), plugin: StorePlugin.id, config: [
                    "databasePath": .string(databaseURL.path),
                    "wikiID": .string(wikiID.rawValue),
                ]),
            ])).entries
    }

    public static func resolve(
        kind: ProductionProfileKind,
        scope: ProductionProfileScope,
        bundlesDirectory: URL? = nil,
        homeDirectory: URL? = nil,
        overlay: String? = nil,
        ambient: PatchFile = PatchFile()
    ) throws -> ResolvedProfile {
        try ProductionProfileResolver.resolve(
            kind: kind, scope: scope, bundlesDirectory: bundlesDirectory,
            homeDirectory: homeDirectory, overlay: overlay, ambient: ambient)
    }

    public static func ambient(databaseURL: URL, wikiID: WikiID) -> PatchFile {
        PatchFile(entries: [
            Entry(id: EntryID("store"), plugin: StorePlugin.id, config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string(wikiID.rawValue),
            ]),
            Entry(id: EntryID("runtime-services"), plugin: PerWikiRuntimePlugin.id, config: [
                "wikiID": .string(wikiID.rawValue),
                "containerDirectory": .string(databaseURL.deletingLastPathComponent().path),
            ]),
        ])
    }
}

public enum ProcessRuntimePlugins {
    public static let agentProviderID = PluginID("process.agent-provider")
    public static let extractionID = PluginID("process.extraction")
    public static let queueID = PluginID("process.queue")
    public static let transportID = PluginID("process.transport")
    public static let rendererID = PluginID("process.renderer")
    public static let embeddingsID = PluginID("process.embeddings")
    public static let urlFetchProviderID = PluginID("process.integration.url-fetch-provider")
    public static let zoteroClientProviderID = PluginID("process.integration.zotero-client-provider")

    public static func definitions(_ factories: ProcessPluginCatalogFactories) -> [PluginDefinition] {
        var definitions = [
            definition(id: agentProviderID, key: ProcessServiceKeys.agentProvider, factory: factories.makeAgentProvider),
            definition(id: extractionID, key: ProcessServiceKeys.extraction, factory: factories.makeExtraction),
            definition(id: embeddingsID, key: ProcessServiceKeys.embeddings, factory: factories.makeEmbeddings),
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
        if let factory = factories.makeURLFetchProvider {
            definitions.append(definition(
                id: urlFetchProviderID,
                key: ProcessServiceKeys.urlFetchProvider,
                factory: factory))
        }
        if let factory = factories.makeZoteroClientProvider {
            definitions.append(definition(
                id: zoteroClientProviderID,
                key: ProcessServiceKeys.zoteroClientProvider,
                factory: factory))
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
            RendererServicesPlugin.definition,
            DaemonTransportPlugin.definition(makeServices: factories.makeDaemonTransport),
            URLFetchIntegrationPlugin.definition,
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
    public static func definitions(
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeCompositionFactory.runtimeFactory
    ) -> [PluginDefinition] {
        [
            StorePlugin.definition,
            SearchPlugin.definition,
            TantivySearchPlugin.definition(makeRuntime: makeTantivyRuntime),
        ]
    }

    public static func build(
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeCompositionFactory.runtimeFactory
    ) throws -> PluginCatalog {
        try PluginCatalog(definitions(makeTantivyRuntime: makeTantivyRuntime))
    }
}

private func baseDefinitions(_ factories: BasePluginCatalogFactories) -> [PluginDefinition] {
    [
        StorePlugin.definition,
        SessionsPlugin.definition,
        PerWikiRuntimePlugin.definition,
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
        EmbeddingsSearchPlugin.definition,
        RenderersPlugin.definition,
        TransportPlugin.definition,
        IntegrationsPlugin.definition,
    ]
}
#endif
