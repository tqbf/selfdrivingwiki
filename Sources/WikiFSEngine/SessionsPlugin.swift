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
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
        interactiveUsageRecorder: @escaping @MainActor (SessionUsage) -> Void = { _ in }
    ) throws {
        let databaseURL = containerDirectory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        let rawStore = try makeStore(databaseURL)
        let bus = rawStore.eventBus ?? WikiEventBus(wikiID: wikiID)
        rawStore.eventBus = bus
        let model = WikiStoreModel(store: rawStore)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            model.readService = WikiReadService(databaseURL: databaseURL)
        }
        // The package-driven fence validator resolves from the machine
        // renderer package store. An unresolvable layout skips validation
        // (nil semantics), matching the no-package contract.
        model.fenceSyntaxValidator = DebugLog.trying("resolve fence validation service", operation: {
            FenceSyntaxValidationService(
                layout: try RendererPackageStoreLayout(appGroupContainerRoot: containerDirectory))
        })
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
            htmlBackend: htmlBackendResolver())
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
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
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
        model.fenceSyntaxValidator = DebugLog.trying("resolve fence validation service", operation: {
            FenceSyntaxValidationService(
                layout: try RendererPackageStoreLayout(appGroupContainerRoot: containerDirectory))
        })
        let searchOwner = childServices.searchFactory.makeOwner(registry: searchRuntimeRegistry)
        model.searchServices = searchOwner.services
        searchOwner.start()
        let pair = childServices.launcherFactory(wikiID: wikiID)
        pair.launcher.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        pair.launcher.onInteractiveUsage = interactiveUsageRecorder
        // Registration-driven recognition + auto-extraction: the active
        // registrations' declared inputs make registered zip-container
        // content (a `.docx`) recognizable at ingestion, and package-only
        // kinds convert on import instead of waiting for a manual Extract
        // tap. The kinds set is DERIVED, never enumerated: an active
        // registration claims the kind AND the host has no backend of its
        // own for it (hostBackendKinds reads the choice categories, not the
        // route display rows). A future package-only kind starts converting
        // on import with no host-policy change — only its typed adapter
        // joins `prepareImportExtractor`.
        let extractionCoordinator = ExtractionCoordinator(services: processServices.extraction)
        let registeredInputs = await processServices.extraction
            .registeredExtractionInputs()
        model.registeredExtractionInputs = registeredInputs
        do {
            let rendererPreparation = try await processServices.renderer.prepareCurrentRegistry()
            model.registeredRendererSourceTypes = rendererPreparation.registeredSourceTypes
        } catch {
            DebugLog.store("Renderer catalog preparation failed during wiki startup: \(error)")
            model.registeredRendererSourceTypes = .none
        }
        model.importAutoExtractionKinds = Set(registeredInputs.claims.map(\.kind))
            .subtracting(ExtractorRouteHostCatalog.hostBackendKinds)
        model.importExtractorProvider = { [extractionCoordinator] kind in
            await extractionCoordinator.prepareImportExtractor(kind: kind)
        }
        // Queue-startup recovery (fetcher packages): the wiki session open
        // owns one stranded-format-job scan. App and daemon use the SAME
        // dedupe keys, so a scan racing the other host converges on one item.
        if let recovering = extractionProvider as? any FetchFormatJobRecovering {
            await recovering.recoverStrandedFormatJobs(
                wikiID: wikiID, store: childServices.store)
        }
        return ProfileWikiSession(
            wikiID: wikiID,
            descriptor: descriptor,
            store: model,
            searchCompositionOwner: searchOwner,
            generationGate: pair.gate,
            agentLauncher: pair.launcher,
            extractionCoordinator: extractionCoordinator,
            queueEngine: processServices.queue,
            extractionProvider: extractionProvider,
            htmlBackend: htmlBackendResolver(),
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
                let sharedGate = await MainActor.run {
                    GenerationGate(laneLimits: LauncherAdmissionPolicy.laneLimits)
                }
                let launcherFactory = LauncherFactory { _ in
                    let launcher = AgentLauncher(
                        generationGate: sharedGate,
                        extractionCoordinator: ExtractionCoordinator(services: extractionServices),
                        providerServices: providerServices,
                        agentLoopService: agentLoopService)
                    // Wiki strategies phase 4 — mandatory production wiring:
                    // pre-launch plan validation resolves assignment titles
                    // through THIS wiki's store (`resolveTitleToID`), so
                    // duplicate resolved page targets are rejected before any
                    // executor launches. The live evaluation harness overrides
                    // this seam with its disposable database. A resolver
                    // FAILURE surfaces as an actionable plan-validation
                    // failure inside `ACPIngestPlanValidation` — never a
                    // silent degrade to new-title folding.
                    launcher.planValidationResolveTitle = { title in
                        try store.resolveTitleToID(title)
                    }
                    // No pdf2md script-path resolver here: production launches
                    // no legacy pdf2md subprocess for the agent seatbelt to
                    // deny (extraction runs through the registry's reviewed
                    // package plugins). The launcher default `{ nil }` stands.
                    return LauncherPair(gate: sharedGate, launcher: launcher)
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

// MARK: - Headless agent-loop runtime composition

/// Observation-only callbacks over the plain agent-loop lifecycle values.
/// Consumers receive the same `AgentTurnStarted` / `AgentStepCompleted` /
/// `AgentTurnCompleted` payloads the loop emits; the observer carries no
/// context and no Cordis surface. The live semantic evaluation harness uses
/// these callbacks to retain per-turn loop-traversal evidence.
public struct AgentLoopTraceObserver: Sendable {
    public typealias TurnStartedHandler = @Sendable (AgentTurnStarted) async -> Void
    public typealias StepCompletedHandler = @Sendable (AgentStepCompleted) async -> Void
    public typealias TurnCompletedHandler = @Sendable (AgentTurnCompleted) async -> Void

    public let onTurnStarted: TurnStartedHandler?
    public let onStepCompleted: StepCompletedHandler?
    public let onTurnCompleted: TurnCompletedHandler?

    public init(
        onTurnStarted: TurnStartedHandler? = nil,
        onStepCompleted: StepCompletedHandler? = nil,
        onTurnCompleted: TurnCompletedHandler? = nil
    ) {
        self.onTurnStarted = onTurnStarted
        self.onStepCompleted = onStepCompleted
        self.onTurnCompleted = onTurnCompleted
    }
}

/// Sendable per-run launcher construction over one booted agent-loop
/// service. Mirrors the daemon provider's launcher configuration — the real
/// loop service plus the caller's provider services — with admission and
/// disposables owned by the caller.
public struct AgentLoopLauncherFactory: Sendable {
    private let agentLoopService: AgentLoopService

    fileprivate init(agentLoopService: AgentLoopService) {
        self.agentLoopService = agentLoopService
    }

    @MainActor
    public func callAsFunction(providerServices: any AgentProviderServices) -> AgentLauncher {
        AgentLauncher(providerServices: providerServices, agentLoopService: agentLoopService)
    }
}

public enum AgentLoopRuntimeError: Error, Equatable, Sendable {
    /// A composition service did not resolve after boot. The boot cleans the
    /// failed profile up before this is thrown.
    case serviceUnavailable(String)
}

/// Boots the headless production agent-loop composition for one explicit
/// database: StorePlugin → SessionsPlugin → ChatsPersistencePlugin →
/// AgentLoopPlugin, plus an optional observation-only trace plugin. This is
/// the same plugin stack the daemon profile boots, exposed as one engine
/// composition seam so non-app hosts (the live evaluation harness, future
/// headless runners) run every agent turn through the production loop
/// without touching the composition machinery themselves.
public enum AgentLoopRuntimeFactory {
    public static func boot(
        databaseURL: URL,
        wikiID: WikiID,
        trace: AgentLoopTraceObserver = AgentLoopTraceObserver()
    ) async throws -> AgentLoopRuntimeHandle {
        let tracePluginID = PluginID("wiki.agent-loop-trace")
        let tracePlugin = PluginDefinition(
            id: tracePluginID,
            dependencies: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
        ) {
            try ComponentDefinition(
                label: "wiki.agent-loop-trace",
                dependencies: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
            ) { activation in
                if let onTurnStarted = trace.onTurnStarted {
                    _ = try await activation.on(AgentLoopEventKeys.turnStarted) { event in
                        await onTurnStarted(event)
                    }
                }
                if let onStepCompleted = trace.onStepCompleted {
                    _ = try await activation.on(AgentLoopEventKeys.stepCompleted) { event in
                        await onStepCompleted(event)
                    }
                }
                if let onTurnCompleted = trace.onTurnCompleted {
                    _ = try await activation.on(AgentLoopEventKeys.turnCompleted) { event in
                        await onTurnCompleted(event)
                    }
                }
            }
        }
        let booted = try await CordisBoot.boot(.init(
            catalog: try PluginCatalog([
                StorePlugin.definition,
                SessionsPlugin.definition,
                ChatsPersistencePlugin.definition,
                AgentLoopPlugin.definition,
                tracePlugin,
            ]),
            layers: [PatchFile(entries: [
                Entry(
                    id: EntryID("store"),
                    plugin: StorePlugin.id,
                    config: [
                        "databasePath": .string(databaseURL.path),
                        "wikiID": .string(wikiID.rawValue),
                    ]),
                Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id),
                Entry(id: EntryID("persistence"), plugin: ChatsPersistencePlugin.id),
                Entry(id: EntryID("agent-loop"), plugin: AgentLoopPlugin.id),
                Entry(id: EntryID("trace"), plugin: tracePluginID),
            ])]))
        do {
            return AgentLoopRuntimeHandle(
                wikiID: wikiID,
                store: try await booted.context.require(StoreServiceKeys.store),
                agentLoopService: try await booted.context.require(AgentLoopServiceKeys.agentLoop),
                profile: booted)
        } catch {
            do { try await booted.shutdown() } catch {
                DebugLog.store("Agent-loop runtime cleanup after resolution failure failed: \(error)")
            }
            throw AgentLoopRuntimeError.serviceUnavailable(String(describing: error))
        }
    }
}

/// Opaque ownership of one booted headless agent-loop runtime. The public
/// surface is plain typed values — the booted loop service, the composed
/// store, a per-run launcher factory, and lifecycle — never a context.
public actor AgentLoopRuntimeHandle {
    public nonisolated let wikiID: WikiID
    /// The REAL `AgentLoopPlugin` service: pre-step gates, request
    /// waterfalls, and turn lifecycle events all traverse the production
    /// path.
    public nonisolated let agentLoopService: AgentLoopService
    /// The store the composition opened on the explicit database.
    public nonisolated let store: any WikiStore
    /// Per-run launcher construction over the booted loop service.
    public nonisolated let launcherFactory: AgentLoopLauncherFactory
    private let profile: BootedProfile
    private var didShutdown = false

    fileprivate init(
        wikiID: WikiID,
        store: any WikiStore,
        agentLoopService: AgentLoopService,
        profile: BootedProfile
    ) {
        self.wikiID = wikiID
        self.store = store
        self.agentLoopService = agentLoopService
        self.launcherFactory = AgentLoopLauncherFactory(agentLoopService: agentLoopService)
        self.profile = profile
    }

    /// Retires the composition. Safe to call more than once.
    public func shutdown() async throws {
        guard !didShutdown else { return }
        didShutdown = true
        do {
            try await profile.shutdown()
        } catch {
            didShutdown = false
            throw error
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
