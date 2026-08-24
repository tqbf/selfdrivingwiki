#if os(macOS)
import Foundation
import Synchronization
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

final class RendererPublicationAdmission: Sendable {
    private let admitted = Mutex(true)

    func invalidate() {
        admitted.withLock { $0 = false }
    }

    @MainActor
    func publish(_ body: () -> Void) -> Bool {
        admitted.withLock { admitted in
            guard admitted else { return false }
            admitted = false
            body()
            return true
        }
    }
}

struct RendererStartupPublication: Sendable {
    let preparation: RendererPreparation
    private let admission: RendererPublicationAdmission

    init(preparation: RendererPreparation, admission: RendererPublicationAdmission) {
        self.preparation = preparation
        self.admission = admission
    }

    @MainActor
    @discardableResult
    func publish(to host: InstalledRendererHost) -> Bool {
        admission.publish { host.apply(preparation) }
    }
}

/// Owns renderer assembly, bundled bootstrap, publication admission, and shutdown.
actor RendererCompositionOwner {
    typealias AssemblyFactory = @Sendable () async throws -> any RendererRuntimeOwning

    nonisolated let services: MutableRendererServices

    private enum State {
        case idle
        case starting(Task<Void, Never>, MutableRendererServices.Installation)
        case installed(any RendererRuntimeOwning, MutableRendererServices.Installation)
        case stopped
    }

    private let assemble: AssemblyFactory
    private let publicationAdmission = RendererPublicationAdmission()
    private var state: State = .idle
    private var startupPreparation: RendererPreparation?
    private var startupError: (any Error)?

    init(
        services: MutableRendererServices = MutableRendererServices(),
        assemble: @escaping AssemblyFactory
    ) {
        self.services = services
        self.assemble = assemble
    }

    func start() {
        guard case .idle = state else { return }
        let installation = MutableRendererServices.Installation()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStartup(installation: installation)
        }
        state = .starting(task, installation)
    }

    func awaitSettled() async {
        guard case .starting(let task, _) = state else { return }
        await task.value
    }

    func consumeStartupPreparation() -> RendererStartupPublication? {
        guard case .installed = state, let startupPreparation else { return nil }
        self.startupPreparation = nil
        return RendererStartupPublication(
            preparation: startupPreparation,
            admission: publicationAdmission)
    }

    func failureDescription() -> String? {
        startupError.map(String.init(describing:))
    }

    func shutdown() async {
        publicationAdmission.invalidate()
        startupPreparation = nil
        switch state {
        case .idle:
            state = .stopped
        case .starting(let task, let installation):
            state = .stopped
            await services.invalidate(installation)
            task.cancel()
            await task.value
        case .installed(let handle, let installation):
            state = .stopped
            await services.invalidate(installation)
            await dispose(handle, late: false)
        case .stopped:
            return
        }
    }

    private func runStartup(
        installation: MutableRendererServices.Installation
    ) async {
        var assembledHandle: (any RendererRuntimeOwning)?
        do {
            let handle = try await assemble()
            assembledHandle = handle
            guard isAdmitted(installation) else {
                await dispose(handle, late: true)
                return
            }
            await services.install(handle.services, for: installation)
            guard isAdmitted(installation) else {
                await services.invalidate(installation)
                await dispose(handle, late: true)
                return
            }
            let preparation = try await handle.services.bootstrapBundledPackage()
            guard isAdmitted(installation) else {
                await services.invalidate(installation)
                await dispose(handle, late: true)
                return
            }
            startupPreparation = preparation
            state = .installed(handle, installation)
            assembledHandle = nil
            startupError = nil
        } catch is CancellationError {
            if let assembledHandle {
                await services.invalidate(installation)
                await dispose(assembledHandle, late: true)
            }
            // Shutdown owns cancellation and leaves the facade unavailable.
        } catch {
            guard isAdmitted(installation) else {
                if let assembledHandle { await dispose(assembledHandle, late: true) }
                return
            }
            await services.invalidate(installation)
            if let assembledHandle { await dispose(assembledHandle, late: true) }
            startupError = error
            state = .idle
            DebugLog.store("Renderer composition startup failed; using Source fallback.")
        }
    }

    private func isAdmitted(_ installation: MutableRendererServices.Installation) -> Bool {
        guard case .starting(_, let current) = state else { return false }
        return current == installation && !Task.isCancelled
    }

    private func dispose(_ handle: any RendererRuntimeOwning, late: Bool) async {
        do { try await handle.dispose() }
        catch {
            let phase = late ? "late" : "shutdown"
            DebugLog.store("Renderer composition \(phase) cleanup failed.")
        }
    }
}

/// App-target injected catalog and stable UI adapter holder.
///
/// Concrete process runtimes are constructed only by the factory closures
/// installed in `ProcessRuntimePlugins`. The committed process-profile rows
/// select which closures activate; this holder does not start a parallel graph.
@MainActor
final class AppProcessPluginCatalog {
    let profileOwner: AppProcessProfileOwner
    let providerServices: MutableAgentProviderServices
    let extractionServices: MutableExtractionServices
    let queueController: LocalQueueRuntimeController
    let transportOwner: DaemonTransportCompositionOwner
    let rendererOwner: RendererCompositionOwner

    init(
        containerDirectory: URL,
        transportBridge: DaemonTransportAppBridge,
        extractionProvider: @escaping @MainActor (any ExtractionServices) -> any QueueExtractionProvider,
        makeIngestionProvider: @escaping @MainActor (
            QueueStore,
            any AgentProviderServices
        ) -> any QueueIngestionProvider
    ) {
        let providerServices = MutableAgentProviderServices()
        let extractionServices = MutableExtractionServices()
        let extractionCredentialStore = KeychainExtractionCredentialStore()
        let acpCredentialStore = KeychainACPCredentialStore()

        let queueDBURL = DebugLog.trying(
            "resolve queue database URL",
            operation: { try DatabaseLocation.queueDatabaseURL() })
            ?? containerDirectory.appendingPathComponent("queue.sqlite", isDirectory: false)
        let queueController = LocalQueueRuntimeController {
            try await QueueRuntimeFactory(
                databaseURL: queueDBURL,
                extractionProvider: await MainActor.run { extractionProvider(extractionServices) },
                makeIngestionProvider: { store in
                    await MainActor.run { makeIngestionProvider(store, providerServices) }
                })
                .assemble()
        }
        let transportOwner = DaemonTransportCompositionOwner {
            try await DaemonTransportRuntimeFactory(
                connectionFactory: transportBridge.connectionFactory,
                configuration: .init(
                    retryInterval: .seconds(30),
                    healthCheckInterval: .seconds(30),
                    healthCheckTimeout: 5,
                    acceptanceDeadline: .seconds(30)))
                .assemble()
        }
        let rendererLayout: RendererPackageStoreLayout
        do {
            rendererLayout = try RendererPackageStoreLayout(appGroupContainerRoot: containerDirectory)
        } catch {
            preconditionFailure("Resolved app-group renderer layout was invalid: \(error)")
        }
        let rendererOwner = RendererCompositionOwner {
            try await RendererRuntimeFactory(
                layout: rendererLayout,
                bundledPackageSource: { BundledRendererPackages.excalidrawResourceURL() },
                reviewedBundledIdentity: .init(
                    packageID: BundledRendererPackages.excalidrawPackageID,
                    version: BundledRendererPackages.excalidrawVersion,
                    registrationID: BundledRendererPackages.excalidrawRegistrationID))
                .assemble()
        }

        self.providerServices = providerServices
        self.extractionServices = extractionServices
        self.queueController = queueController
        self.transportOwner = transportOwner
        self.rendererOwner = rendererOwner

        profileOwner = AppProcessProfileOwner(factories: ProcessPluginCatalogFactories(
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
                        resolvePermissionPolicy: { operation in
                            let key: String
                            switch operation {
                            case .chat: key = AgentLauncher.PermissionModeKey.chat
                            case .ingest: key = AgentLauncher.PermissionModeKey.ingest
                            case .lint: key = AgentLauncher.PermissionModeKey.lint
                            }
                            let raw = UserDefaults.standard.string(forKey: key) ?? ""
                            return PermissionPolicy(rawValue: raw) ?? .bypass
                        })
                        .assemble()
                    await providerServices.install(handle.services)
                    return ProcessRuntimeLease(service: providerServices) {
                        try await handle.dispose()
                    }
                },
                makeExtraction: {
                    let owner = ExtractionCompositionOwner(services: extractionServices) {
                        try await ExtractionRuntimeFactory(
                            readConfiguration: { ExtractionConfig.load(from: containerDirectory) },
                            readCredential: { extractionCredentialStore.secret($0) },
                            resolveACP: { configuration in
                                ACPExtractionClient.resolveProvider(
                                    containerDirectory: containerDirectory,
                                    acpProviderId: configuration.acpProviderId,
                                    acpCredentialStore: acpCredentialStore)
                            },
                            httpFetcher: URLSessionRequestFetcher(),
                            makeLocalExtractor: {
                                await MainActor.run { LocalPdf2MarkdownExtractor() }
                            })
                            .assemble()
                    }
                    await owner.start()
                    await owner.awaitSettled()
                    if let failure = await owner.failureDescription() {
                        throw AppProcessPluginCatalogError.runtimeUnavailable("extraction: \(failure)")
                    }
                    return ProcessRuntimeLease(service: extractionServices) {
                        await owner.shutdown()
                    }
                },
                makeQueue: {
                    await MainActor.run { queueController.start() }
                    await queueController.awaitSettled()
                    if let failure = await MainActor.run(body: { queueController.startupError }) {
                        throw AppProcessPluginCatalogError.runtimeUnavailable("queue: \(failure)")
                    }
                    return ProcessRuntimeLease(service: queueController.client) {
                        _ = await queueController.dispose()
                    }
                },
                makeTransport: {
                    await transportOwner.start()
                    return ProcessRuntimeLease(service: transportOwner.services) {
                        await transportOwner.shutdown()
                    }
                },
                makeRenderer: {
                    await rendererOwner.start()
                    await rendererOwner.awaitSettled()
                    if let failure = await rendererOwner.failureDescription() {
                        throw AppProcessPluginCatalogError.runtimeUnavailable("renderer: \(failure)")
                    }
                    return ProcessRuntimeLease(service: rendererOwner.services) {
                        await rendererOwner.shutdown()
                    }
                }), homeDirectory: containerDirectory)
    }

    /// Constructs the Settings-only launcher as a UI adapter over resolved
    /// process facades. It is intentionally outside Cordis because
    /// `AgentLauncher` is main-actor UI state, but its construction remains in
    /// the app-target injected catalog boundary rather than `WikiFSApp.init`.
    func makeSettingsLauncher(extractionCoordinator: ExtractionCoordinator) -> AgentLauncher {
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
        let launcher = AgentLauncher(
            generationGate: gate,
            extractionCoordinator: extractionCoordinator,
            providerServices: providerServices)
        launcher.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
        return launcher
    }
}

enum AppProcessPluginCatalogError: Error {
    case runtimeUnavailable(String)
}
#endif
