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
    /// The process-owned registry inherited by every wiki profile.
    public static let extractionBackends = ServiceKey<ExtractionBackendRegistry>(label: "process.extraction-backends")
    /// The retained process extraction graph. The registry key above is the
    /// consumer seam, while this key keeps the reconciler and host alive until
    /// process shutdown.
    public static let extractionContext = ServiceKey<ProcessExtractionContext>(label: "process.extraction-context")
    public static let queue = ServiceKey<any QueueEngineClient>(label: "process.queue")
    public static let transport = ServiceKey<DaemonTransportServices>(label: "process.transport")
    public static let renderer = ServiceKey<any RendererServices>(label: "process.renderer")
    public static let embeddings = ServiceKey<EmbeddingsSearchProvider>(label: "process.embeddings")
    public static let urlFetchProvider = ServiceKey<URLFetchProvider>(label: "process.integration.url-fetch-provider")
    public static let zoteroClientProvider = ServiceKey<ZoteroClientProvider>(label: "process.integration.zotero-client-provider")
    public static let compositionInputs = ServiceKey<ProcessCompositionInputs>(label: "process.inputs")
}

public struct AgentProviderProcessInput: Sendable {
    public let services: MutableAgentProviderServices
    public let readConfiguration: AgentProviderRuntime.ConfigurationReader
    public let resolveCommand: AgentProviderRuntime.CommandResolver
    public let readCredential: AgentProviderRuntime.CredentialReader
    /// #1159: resolves the selected provider's known secret env variables
    /// from the shared credential service at preparation time. Defaults to an
    /// empty map (no spawn secrets).
    public let readSpawnSecrets: AgentProviderRuntime.SpawnSecretReader
    public let resolvePermissionPolicy: AgentProviderRuntime.PermissionPolicyResolver
    public let makeBackend: AgentProviderRuntime.BackendFactory
    public let probeCatalog: AgentProviderRuntime.CatalogProbe

    public init(
        services: MutableAgentProviderServices,
        readConfiguration: @escaping AgentProviderRuntime.ConfigurationReader,
        resolveCommand: @escaping AgentProviderRuntime.CommandResolver,
        readCredential: @escaping AgentProviderRuntime.CredentialReader,
        readSpawnSecrets: @escaping AgentProviderRuntime.SpawnSecretReader = { _ in [:] },
        resolvePermissionPolicy: @escaping AgentProviderRuntime.PermissionPolicyResolver,
        makeBackend: @escaping AgentProviderRuntime.BackendFactory = { policy, budget, ceiling in
            AgentBackendFactory.makeBackend(policy: policy, budget: budget, turnCeilingTimeout: ceiling)
        },
        probeCatalog: @escaping AgentProviderRuntime.CatalogProbe = { provider, command, apiKey in
            try await ACPProviderModelProbe(provider: provider, resolvedCommand: command, apiKey: apiKey)
                .discoverObservation()
        }
    ) {
        self.services = services
        self.readConfiguration = readConfiguration
        self.resolveCommand = resolveCommand
        self.readCredential = readCredential
        self.readSpawnSecrets = readSpawnSecrets
        self.resolvePermissionPolicy = resolvePermissionPolicy
        self.makeBackend = makeBackend
        self.probeCatalog = probeCatalog
    }
}

public struct ExtractionProcessInput: Sendable {
    public let services: MutableExtractionServices
    public let readConfiguration: ExtractionRuntime.ConfigurationReader
    public let readCredential: ExtractionPluginFactory.CredentialReader
    public let resolveACP: ExtractionPluginFactory.ACPResolver
    public let httpFetcher: any HTTPRequestFetcher
    public let packageContainerDirectory: URL
    public let packageProcessRole: ExtractorPackageProcessRole
    /// App-only hook that publishes the reviewed bundled revisions into the
    /// durable machine store before the first reconciliation. The daemon and
    /// the CLI pass nil: only the app is a catalog writer. A failed bootstrap
    /// keeps the bundled revisions in use through the reviewed overlay.
    public let bootstrapReviewedPackages: (@Sendable () async -> Void)?

    public init(
        services: MutableExtractionServices,
        readConfiguration: @escaping ExtractionRuntime.ConfigurationReader,
        readCredential: @escaping ExtractionPluginFactory.CredentialReader,
        resolveACP: @escaping ExtractionPluginFactory.ACPResolver,
        httpFetcher: any HTTPRequestFetcher,
        packageContainerDirectory: URL? = nil,
        packageProcessRole: ExtractorPackageProcessRole = .app,
        bootstrapReviewedPackages: (@Sendable () async -> Void)? = nil
    ) {
        self.services = services
        self.readConfiguration = readConfiguration
        self.readCredential = readCredential
        self.resolveACP = resolveACP
        self.httpFetcher = httpFetcher
        self.packageContainerDirectory = packageContainerDirectory ?? FileManager.default.temporaryDirectory
        self.packageProcessRole = packageProcessRole
        self.bootstrapReviewedPackages = bootstrapReviewedPackages
    }
}

public struct ProcessCompositionInputs: Sendable {
    public typealias QueueAssembly = @Sendable () async throws -> ProcessRuntimeLease<any QueueEngineClient>
    public typealias TransportAssembly = @Sendable () async throws -> ProcessRuntimeLease<DaemonTransportServices>
    public typealias RendererAssembly = @Sendable () async throws -> ProcessRuntimeLease<any RendererServices>

    public let agentProvider: AgentProviderProcessInput
    public let extraction: ExtractionProcessInput
    public let queueAssembly: QueueAssembly?
    public let transportAssembly: TransportAssembly?
    public let rendererAssembly: RendererAssembly?

    public init(
        agentProvider: AgentProviderProcessInput,
        extraction: ExtractionProcessInput,
        queueAssembly: QueueAssembly? = nil,
        transportAssembly: TransportAssembly? = nil,
        rendererAssembly: RendererAssembly? = nil
    ) {
        self.agentProvider = agentProvider
        self.extraction = extraction
        self.queueAssembly = queueAssembly
        self.transportAssembly = transportAssembly
        self.rendererAssembly = rendererAssembly
    }
}

public struct ProcessPluginCatalogFactories: Sendable {
    public typealias EmbeddingsFactory = @Sendable () async throws -> ProcessRuntimeLease<EmbeddingsSearchProvider>
    public typealias URLFetchProviderFactory = @Sendable () async throws -> ProcessRuntimeLease<URLFetchProvider>
    public typealias ZoteroClientProviderFactory = @Sendable () async throws -> ProcessRuntimeLease<ZoteroClientProvider>

    public let compositionInputs: ProcessCompositionInputs
    public let makeEmbeddings: EmbeddingsFactory
    public let makeURLFetchProvider: URLFetchProviderFactory?
    public let makeZoteroClientProvider: ZoteroClientProviderFactory?

    public init(
        compositionInputs: ProcessCompositionInputs,
        makeEmbeddings: @escaping EmbeddingsFactory,
        makeURLFetchProvider: URLFetchProviderFactory? = nil,
        makeZoteroClientProvider: ZoteroClientProviderFactory? = nil
    ) {
        self.compositionInputs = compositionInputs
        self.makeEmbeddings = makeEmbeddings
        self.makeURLFetchProvider = makeURLFetchProvider
        self.makeZoteroClientProvider = makeZoteroClientProvider
    }
}

public struct BasePluginCatalogFactories: Sendable {
    public let agentProviderServices: any AgentProviderServices

    public init(agentProviderServices: any AgentProviderServices) {
        self.agentProviderServices = agentProviderServices
    }
}

public struct AppPluginCatalogFactories: Sendable {
    public let base: BasePluginCatalogFactories
    public let makeDaemonTransport: RegisteredTransportProvider.Factory
    public let makeTantivyRuntime: SearchRuntimeFactory.Factory

    public init(
        base: BasePluginCatalogFactories,
        makeDaemonTransport: @escaping RegisteredTransportProvider.Factory,
        makeTantivyRuntime: @escaping SearchRuntimeFactory.Factory = SearchRuntimeCompositionFactory.runtimeFactory
    ) {
        self.base = base
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
    /// The process-scoped extraction adapter registry. The Settings package
    /// lifecycle list reads installed exact registrations from it.
    public let extractionBackends: ExtractionBackendRegistry
    /// The process package-extraction context when the extraction plugin booted
    /// one. The Settings package lifecycle uses it for reconciliation
    /// observation and deterministic post-mutation wakes. nil is legal: the
    /// context is optional at resolution, and consumers degrade to read-only.
    public let extractionContext: ProcessExtractionContext?
    public let queue: any QueueEngineClient
    public let transport: DaemonTransportServices
    public let renderer: any RendererServices

    internal static func resolve(from profile: BootedProfile) async throws -> AppProcessServices {
        AppProcessServices(
            agentProvider: try await profile.context.require(ProcessServiceKeys.agentProvider),
            extraction: try await profile.context.require(ProcessServiceKeys.extraction),
            extractionBackends: try await profile.context.require(ProcessServiceKeys.extractionBackends),
            extractionContext: try await profile.context.find(ProcessServiceKeys.extractionContext),
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
    private var invariantCoordinatorTask: Task<RuntimeInvariantCoordinator?, Never>?
    private var invariantCoordinator: RuntimeInvariantCoordinator?
    private var shutdownStarted = false

    internal init(profile: BootedProfile) {
        self.profile = profile
    }

    private func diagnosticsCoordinator() async -> RuntimeInvariantCoordinator? {
        if let invariantCoordinator { return invariantCoordinator }
        guard !shutdownStarted, let profile else { return nil }
        if invariantCoordinatorTask == nil {
            let context = profile.context
            invariantCoordinatorTask = Task {
                do {
                    guard case .process? = try await context.scopeDiagnostics().descriptor else { return nil }
                    let coordinator = try RuntimeInvariantCoordinator(
                        processContext: context,
                        sink: DebugLogInvariantViolationSink())
                    try await coordinator.start()
                    return coordinator
                } catch {
                    DebugLog.store("Runtime invariant startup failed: \(error)")
                    return nil
                }
            }
        }
        guard let task = invariantCoordinatorTask else { return nil }
        let coordinator = await task.value
        guard !shutdownStarted, self.profile?.context.id == profile.context.id else {
            await coordinator?.shutdown()
            return nil
        }
        invariantCoordinator = coordinator
        return coordinator
    }

    internal func bootChild(
        wikiID: WikiID,
        catalog: PluginCatalog,
        layers: [PatchFile],
        host: WikiScopeHostAssociation = .app
    ) async throws -> AppServices {
        guard !shutdownStarted, let profile else {
            throw ProfileLifetimeError.shutdownStarted
        }
        let child = try await CordisBoot.boot(.init(
            catalog: catalog,
            layers: layers,
            parent: profile.context,
            descriptor: .wiki(wikiID)))
        guard !shutdownStarted else {
            try await child.shutdown()
            throw ProfileLifetimeError.shutdownStarted
        }
        do {
            let services = try await AppServices.resolve(from: child)
            if let coordinator = await diagnosticsCoordinator() {
                try await coordinator.observeWiki(
                    profile: child,
                    profileWikiID: wikiID,
                    store: services.store,
                    databaseWikiID: wikiID,
                    host: host)
            }
            guard !shutdownStarted else { throw ProfileLifetimeError.shutdownStarted }
            return services
        } catch {
            do { try await child.shutdown() } catch let cleanupError {
                DebugLog.store("Child profile cleanup after resolution failure failed: \(cleanupError)")
            }
            throw error
        }
    }

    internal func scopeDiagnostics() async throws -> ScopeDiagnosticsSnapshot {
        guard let profile else { throw ProfileLifetimeError.shutdownStarted }
        return try await profile.context.scopeDiagnostics()
    }

    public func shutdown() async throws {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        let ownedProfile = profile
        let coordinatorTask = invariantCoordinatorTask
        let coordinator = invariantCoordinator
        profile = nil
        invariantCoordinatorTask = nil
        invariantCoordinator = nil
        if let coordinator {
            await coordinator.shutdown()
        } else if let coordinatorTask {
            await coordinatorTask.value?.shutdown()
        }
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
                layers: [PatchFile(entries: try ProductionProfiles.appProcess(homeDirectory: homeDirectory))],
                descriptor: .process(.app)))
        }
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

    internal static func resolve(from profile: BootedProfile) async throws -> DaemonProcessServices {
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

    private typealias ProcessStartup = (
        profile: BootedProfile,
        services: DaemonProcessServices,
        coordinator: RuntimeInvariantCoordinator?)

    private var startupTask: Task<ProcessStartup, Error>?
    private var process: (BootedProfile, DaemonProcessServices)?
    private var invariantCoordinator: RuntimeInvariantCoordinator?
    private var wikis: [WikiID: WikiLifecycle] = [:]
    private var shutdownStarted = false

    public init(boot: @escaping Boot, bootWiki: @escaping BootWiki) {
        self.boot = boot
        self.bootWiki = bootWiki
    }

    public static func production(
        containerDirectory: URL
    ) throws -> DaemonProcessProfileOwner {
        let providerServices = MutableAgentProviderServices()
        let extractionServices = MutableExtractionServices()
        let extractionCredentialStore = KeychainExtractionCredentialStore()
        let acpCredentialStore = KeychainACPCredentialStore()
        let processFactories = ProcessPluginCatalogFactories(
            compositionInputs: ProcessCompositionInputs(
                agentProvider: AgentProviderProcessInput(
                    services: providerServices,
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
                    readSpawnSecrets: { providerID in
                        ProviderSecretEnvironment.resolvedSpawnSecrets(
                            for: providerID,
                            resolving: KeychainCredentialService())
                    },
                    resolvePermissionPolicy: { _ in .bypass }),
                extraction: ExtractionProcessInput(
                    services: extractionServices,
                    readConfiguration: { ExtractionConfig.load(from: containerDirectory) },
                    readCredential: { extractionCredentialStore.secret($0) },
                    resolveACP: { configuration in
                        ACPExtractionClient.resolveProvider(
                            containerDirectory: containerDirectory,
                            acpProviderId: configuration.acpProviderId,
                            acpCredentialStore: acpCredentialStore)
                    },
                    httpFetcher: URLSessionRequestFetcher(),
                    packageContainerDirectory: containerDirectory,
                    packageProcessRole: .daemon)
            ),
            makeEmbeddings: {
                ProcessRuntimeLease(
                    service: .unavailable(identifier: "unavailable-daemon"),
                    dispose: {})
            })
        let processCatalog = try ProcessPluginCatalog.build(factories: processFactories)
        let childCatalog = try DaemonPluginCatalog.build(factories: .init(base: .init(
            agentProviderServices: providerServices)))
        return DaemonProcessProfileOwner(
            boot: {
                try await CordisBoot.boot(.init(
                    catalog: processCatalog,
                    layers: [PatchFile(entries: try ProductionProfiles.daemonProcess(homeDirectory: containerDirectory))],
                    descriptor: .process(.daemon)))
            },
            bootWiki: { wikiID, processProfile in
                let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
                return try await CordisBoot.boot(.init(
                    catalog: childCatalog,
                    layers: [PatchFile(entries: try ProductionProfiles.daemon(
                        databaseURL: databaseURL, wikiID: wikiID, homeDirectory: containerDirectory))],
                    parent: processProfile.context,
                    descriptor: .wiki(wikiID)))
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
                    let services = try await DaemonProcessServices.resolve(from: profile)
                    let coordinator: RuntimeInvariantCoordinator?
                    do {
                        let candidate = try RuntimeInvariantCoordinator(
                            processContext: profile.context,
                            sink: DebugLogInvariantViolationSink())
                        try await candidate.start()
                        coordinator = candidate
                    } catch {
                        DebugLog.store("Daemon runtime invariant startup failed: \(error)")
                        coordinator = nil
                    }
                    return (profile, services, coordinator)
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
            await resolved.coordinator?.shutdown()
            try await resolved.profile.shutdown()
            throw CancellationError()
        }
        process = (resolved.profile, resolved.services)
        invariantCoordinator = resolved.coordinator
        return resolved.services
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
            let coordinator = invariantCoordinator
            let task = Task {
                let profile = try await bootWiki(wikiID, processProfile)
                do {
                    let services = try await AppServices.resolve(from: profile)
                    try await coordinator?.observeWiki(
                        profile: profile,
                        profileWikiID: wikiID,
                        store: services.store,
                        databaseWikiID: wikiID,
                        host: .daemon(cacheKey: wikiID))
                    return services
                } catch {
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
        await invariantCoordinator?.shutdown()
        invariantCoordinator = nil
        if let profile = process?.0 {
            do { try await profile.shutdown() } catch {
                DebugLog.store("Daemon process profile shutdown failed: \(error)")
            }
        } else if let startupTask {
            do {
                let result = try await startupTask.value
                await result.coordinator?.shutdown()
                try await result.profile.shutdown()
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
        let extractionBackends: ExtractionBackendRegistry
        if let inherited = try await profile.context.find(ProcessServiceKeys.extractionBackends) {
            extractionBackends = inherited
        } else {
            // Keep the legacy lookup for profiles that do not yet mount the
            // process extraction graph. Production process profiles always use
            // the inherited process registry above.
            extractionBackends = try await profile.context.require(ExtractionServiceKeys.backends)
        }
        return AppServices(
            lifetime: ProfileLifetime(profile: profile),
            store: try await profile.context.require(StoreServiceKeys.store),
            readService: try await profile.context.require(StoreServiceKeys.readService),
            extractionBackends: extractionBackends,
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
    public static let inputsID = PluginID("process.inputs")
    public static let agentProviderID = PluginID("process.agent-provider")
    public static let extractionID = PluginID("process.extraction")
    public static let extractionBackendsID = PluginID("process.extraction-backends")
    public static let queueID = PluginID("process.queue")
    public static let transportID = PluginID("process.transport")
    public static let rendererID = PluginID("process.renderer")
    public static let embeddingsID = PluginID("process.embeddings")
    public static let urlFetchProviderID = PluginID("process.integration.url-fetch-provider")
    public static let zoteroClientProviderID = PluginID("process.integration.zotero-client-provider")

    public static func definitions(_ factories: ProcessPluginCatalogFactories) -> [PluginDefinition] {
        var definitions = [
            inputsDefinition(factories.compositionInputs),
            agentProviderDefinition,
            extractionDefinition,
            directDefinition(id: embeddingsID, key: ProcessServiceKeys.embeddings, factory: factories.makeEmbeddings),
        ]
        if factories.compositionInputs.queueAssembly != nil {
            definitions.append(gatewayDefinition(
                id: queueID,
                key: ProcessServiceKeys.queue,
                gateway: { $0.queueAssembly }))
        }
        if factories.compositionInputs.transportAssembly != nil {
            definitions.append(gatewayDefinition(
                id: transportID,
                key: ProcessServiceKeys.transport,
                gateway: { $0.transportAssembly }))
        }
        if factories.compositionInputs.rendererAssembly != nil {
            definitions.append(gatewayDefinition(
                id: rendererID,
                key: ProcessServiceKeys.renderer,
                gateway: { $0.rendererAssembly }))
        }
        if let factory = factories.makeURLFetchProvider {
            definitions.append(directDefinition(
                id: urlFetchProviderID,
                key: ProcessServiceKeys.urlFetchProvider,
                factory: factory))
        }
        if let factory = factories.makeZoteroClientProvider {
            definitions.append(directDefinition(
                id: zoteroClientProviderID,
                key: ProcessServiceKeys.zoteroClientProvider,
                factory: factory))
        }
        return definitions
    }

    private static func inputsDefinition(_ inputs: ProcessCompositionInputs) -> PluginDefinition {
        PluginDefinition(id: inputsID, provisions: [ServiceDependency(ProcessServiceKeys.compositionInputs)]) {
            try ComponentDefinition(
                label: inputsID.rawValue,
                provisions: [ServiceDependency(ProcessServiceKeys.compositionInputs)]) { activation in
                    _ = try await activation.supply(ProcessServiceKeys.compositionInputs, value: inputs)
                }
        }
    }

    private static let agentProviderDefinition = PluginDefinition(
        id: agentProviderID,
        dependencies: [ServiceDependency(ProcessServiceKeys.compositionInputs)],
        provisions: [ServiceDependency(ProcessServiceKeys.agentProvider)]
    ) {
        try ComponentDefinition(
            label: agentProviderID.rawValue,
            dependencies: [ServiceDependency(ProcessServiceKeys.compositionInputs)],
            provisions: [ServiceDependency(ProcessServiceKeys.agentProvider)]) { activation in
                let input = try await activation.require(ProcessServiceKeys.compositionInputs).agentProvider
                let installation = MutableAgentProviderServices.Installation()
                let handle = try await AgentProviderRuntimeFactory(
                    readConfiguration: input.readConfiguration,
                    resolveCommand: input.resolveCommand,
                    readCredential: input.readCredential,
                    readSpawnSecrets: input.readSpawnSecrets,
                    resolvePermissionPolicy: input.resolvePermissionPolicy,
                    makeBackend: input.makeBackend,
                    probeCatalog: input.probeCatalog)
                    .assemble()
                await input.services.install(handle.services, for: installation)
                _ = try await activation.effect { _ in
                    await input.services.invalidate(installation)
                    try await handle.dispose()
                }
                _ = try await activation.supply(ProcessServiceKeys.agentProvider, value: input.services)
            }
    }

    private static let extractionDefinition = PluginDefinition(
        id: extractionID,
        dependencies: [ServiceDependency(ProcessServiceKeys.compositionInputs)],
        provisions: [
            ServiceDependency(ProcessServiceKeys.extraction),
            ServiceDependency(ProcessServiceKeys.extractionBackends),
            ServiceDependency(ProcessServiceKeys.extractionContext),
        ]
    ) {
        try ComponentDefinition(
            label: extractionID.rawValue,
            dependencies: [ServiceDependency(ProcessServiceKeys.compositionInputs)],
            provisions: [
                ServiceDependency(ProcessServiceKeys.extraction),
                ServiceDependency(ProcessServiceKeys.extractionBackends),
                ServiceDependency(ProcessServiceKeys.extractionContext),
            ]) { activation in
                let input = try await activation.require(ProcessServiceKeys.compositionInputs).extraction
                // One process-wide adapter authority. Wiki sessions inherit
                // this instance; opening more wikis never creates more
                // registries or package activations.
                if let bootstrapReviewed = input.bootstrapReviewedPackages {
                    await bootstrapReviewed()
                }
                let packageLayout = try ExtractorPackageStoreLayout(
                    appGroupContainerRoot: input.packageContainerDirectory,
                    processRole: input.packageProcessRole)
                let extractionContext = try await ProcessExtractionContext.assemble(
                    layout: packageLayout,
                    executor: ManagedExtractorProcessExecutor())
                _ = await extractionContext.reconcileNow()
                _ = try await activation.supply(
                    ProcessServiceKeys.extractionBackends,
                    value: extractionContext.registry)
                _ = try await activation.supply(
                    ProcessServiceKeys.extractionContext,
                    value: extractionContext)
                let installation = MutableExtractionServices.Installation()
                let services = try await ProcessExtractionServices.assemble(
                    context: extractionContext,
                    input: input)
                await input.services.install(services, for: installation)
                _ = try await activation.effect { _ in
                    await input.services.invalidate(installation)
                    await services.shutdown()
                }
                _ = try await activation.supply(ProcessServiceKeys.extraction, value: input.services)
            }
    }

    private static func gatewayDefinition<Service: Sendable>(
        id: PluginID,
        key: ServiceKey<Service>,
        gateway: @escaping @Sendable (ProcessCompositionInputs) -> (@Sendable () async throws -> ProcessRuntimeLease<Service>)?
    ) -> PluginDefinition {
        PluginDefinition(
            id: id,
            dependencies: [ServiceDependency(ProcessServiceKeys.compositionInputs)],
            provisions: [ServiceDependency(key)]) {
                try ComponentDefinition(
                    label: id.rawValue,
                    dependencies: [ServiceDependency(ProcessServiceKeys.compositionInputs)],
                    provisions: [ServiceDependency(key)]) { activation in
                        let inputs = try await activation.require(ProcessServiceKeys.compositionInputs)
                        guard let assemble = gateway(inputs) else {
                            throw CordisFailure("process assembly gateway is unavailable: \(id.rawValue)")
                        }
                        let lease = try await assemble()
                        _ = try await activation.supply(key, value: lease.service)
                        _ = try await activation.effect { _ in try await lease.dispose() }
                    }
            }
    }

    private static func directDefinition<Service: Sendable>(
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
        SearchPlugin.definition,
        EmbeddingsSearchPlugin.definition,
        RenderersPlugin.definition,
        TransportPlugin.definition,
        IntegrationsPlugin.definition,
    ]
}
#endif
