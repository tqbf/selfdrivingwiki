import Cordis
import CordisLoader
import Foundation
import WikiFSCore

/// Admits a revision exactly while the current process registry holds one of
/// its active exact installations. The registry is authoritative because every
/// generated-plugin batch commit and cleanup effect flows through it, so this
/// gate cannot drift from the plugin lifecycle without a component failing
/// visibly.
public final class RegistryMembershipAdmission: ProcessPackageAdmissionChecking, Sendable {
    private let registry: ExtractionBackendRegistry

    public init(registry: ExtractionBackendRegistry) {
        self.registry = registry
    }

    public func isAdmitted(_ revision: ExtractorPackageRevisionID) async -> Bool {
        await registry.containsRevision(revision)
    }
}

/// The one process-scoped extraction context per app or daemon process. Wiki
/// profiles, queue workers, direct UI, and daemon workloads all resolve this
/// same assembly; opening more wikis never creates more registries, dynamic
/// plugin hosts, package activations, or managed executors. App and daemon
/// processes naturally own separate instances.
///
/// Shutdown ordering (full extraction-context shutdown only): stop accepting
/// new preparations is implicit because callers drop their prepared operations;
/// disposing the host runs every plugin cleanup effect to preparation
/// quiescence; managed operations own their snapshots independently (Phase 4b)
/// and are cancelled by the executor teardown at full executor disposal.
public struct ProcessExtractionContext: Sendable {
    public let cordisContext: CordisContext
    public let registry: ExtractionBackendRegistry
    public let host: DynamicPluginHost
    public let reconciler: ExtractorPackagePluginReconciler
    public let layout: ExtractorPackageStoreLayout
    private let catalogReader: any ExtractorPackageCatalogReading
    /// Retained for the process lifetime so local and cross-process catalog
    /// wakes reach this context's reconciler. Wakes are hints only.
    private let wakeObserver: ExtractorCatalogWakeObserver

    /// Assembles a fresh process context. Only this path may supply the five
    /// fixed services; consumers must use `cordisContext.require` equivalents
    /// via components, never supply competing values.
    public static func assemble(
        appGroupContainerRoot: URL,
        admissionOverride: (any ProcessPackageAdmissionChecking)? = nil,
        executor: any ManagedProcessExecuting = ManagedExtractorProcessExecutor(),
        reviewedPackageRoot: URL? = nil
    ) async throws -> ProcessExtractionContext {
        let layout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: appGroupContainerRoot,
            processRole: .app)
        return try await assemble(
            layout: layout,
            admissionOverride: admissionOverride,
            executor: executor,
            reviewedPackageRoot: reviewedPackageRoot)
    }

    /// Test-visible variant accepting an explicit role-scoped layout.
    public static func assemble(
        layout: ExtractorPackageStoreLayout,
        admissionOverride: (any ProcessPackageAdmissionChecking)? = nil,
        executor: any ManagedProcessExecuting = ManagedExtractorProcessExecutor(),
        reviewedPackageRoot: URL? = nil,
        reviewedPackages: [ReviewedExtractorPackage] = ReviewedExtractorPackages.all
    ) async throws -> ProcessExtractionContext {
        let cordisContext = CordisContext()
        let registry = ExtractionBackendRegistry()
        let durableReader = ExtractorPackageCatalogReader(layout: layout)

        // Reviewed packages are admitted into this process's own operation
        // root, so the application and the daemon can both run them before the
        // application publishes them. This writes nothing shared.
        let overlay = ReviewedExtractorPackageOverlay.resolve(
            layout: layout,
            explicitRoot: reviewedPackageRoot,
            packages: reviewedPackages)
        for notice in overlay.diagnostics {
            DebugLog.extraction("extractor overlay: \(notice)")
        }
        let catalogReader = ReviewedOverlayCatalogReader(
            durable: durableReader,
            overlay: overlay)
        let sourceLocator = ReviewedOverlaySourceLocator(
            layout: layout,
            overlay: overlay,
            durable: durableReader)

        try await cordisContext.supply(ExtractionServiceKeys.backends, value: registry)
        try await cordisContext.supply(
            ExtractionServiceKeys.extractorCatalogReader,
            value: catalogReader)
        try await cordisContext.supply(
            ExtractionServiceKeys.managedProcessExecutor,
            value: executor)
        try await cordisContext.supply(
            ExtractionServiceKeys.packageStoreLayout,
            value: layout)
        try await cordisContext.supply(
            ExtractionServiceKeys.packageSourceLocator,
            value: sourceLocator)

        let host = DynamicPluginHost(context: cordisContext)
        let admission = admissionOverride ?? RegistryMembershipAdmission(registry: registry)
        try await cordisContext.supply(
            ExtractionServiceKeys.packageAdmissionChecker,
            value: admission)

        // Host-owned operation-credential resolution (#1159). Both the app
        // and the daemon resolve the shared binding independently in their
        // own processes; the resolver is never exposed to a package process
        // (it stays a host-side Cordis service of the GENERATED PLUGIN, not
        // of the package).
        let operationCredentialResolver = ExtractorOperationCredentialResolver(
            admission: admission,
            catalogReader: catalogReader,
            authorizationReader: ExtractorCredentialAuthorizationReader(
                layout: ExtractorCredentialAuthorizationStoreLayout(
                    appGroupContainerRoot: layout.appGroupContainerRoot)),
            credentials: KeychainCredentialService())
        try await cordisContext.supply(
            ExtractionServiceKeys.operationCredentialResolver,
            value: operationCredentialResolver)

        let reconciler = ExtractorPackagePluginReconciler(
            host: host,
            catalogReader: catalogReader,
            layout: layout,
            sourceLocator: sourceLocator)
        // The observer holds only the reconciler, so a wake can never carry a
        // generation, a package payload, or another process's lifecycle state.
        let wakeObserver = ExtractorCatalogWakeObserver(scopeRoot: layout.root) { [reconciler] in
            _ = await reconciler.reconcileNow()
        }
        return ProcessExtractionContext(
            cordisContext: cordisContext,
            registry: registry,
            host: host,
            reconciler: reconciler,
            layout: layout,
            catalogReader: catalogReader,
            wakeObserver: wakeObserver)
    }

    /// Applies one wake through the process coalescer and awaits the pass.
    /// Production wakes arrive asynchronously; this is the deterministic entry
    /// point for settings refresh and tests.
    public func receiveCatalogWake() async {
        await wakeObserver.receiveWake()
    }

    /// Applies the current durable generation. Cross-process wakes arrive here
    /// as hints; unchanged generations short-circuit inside the reconciler.
    @discardableResult
    public func reconcileNow(force: Bool = false) async -> ExtractorPackageReconciliationReport {
        await reconciler.reconcileNow(force: force)
    }

    /// Observation snapshot used by settings UI and diagnostics surfaces.
    public func observationSnapshot() async -> (
        appliedGeneration: UInt64?,
        hostedPlugins: [DynamicPluginInspection],
        retainedFailures: [ExtractorPackageReconciliationFailure],
        waitingRevisionIDs: Set<ExtractorPackageRevisionID>
    ) {
        await reconciler.observation()
    }

    /// Validated package registrations available for route selection. This uses
    /// the same durable-plus-reviewed catalog that drives reconciliation.
    public func availableRegistrationSnapshots() -> [ExtractorRouteRegistrationSnapshot] {
        let catalog: ExtractorPackageCatalog
        do {
            catalog = try catalogReader.read()
        } catch {
            DebugLog.extraction("extractor route choices: catalog unreadable")
            return []
        }
        let reviewedRevisions = Set(ReviewedExtractorPackages.all.map(\.revision))
        return catalog.records.flatMap { record in
            record.registrations.map { registration in
                ExtractorRouteRegistrationSnapshot(
                    reference: ExtractorReference(
                        revision: record.revision,
                        registrationID: registration.id),
                    sourceCategory: reviewedRevisions.contains(record.revision)
                        ? .reviewedPackage : .installedPackage,
                    displayName: registration.displayName,
                    packageName: record.displayName,
                    kinds: registration.kinds,
                    mimeTypes: registration.mimeTypes,
                    filenameExtensions: registration.filenameExtensions,
                    credentialRequirements: registration.credentialRequirements)
            }
        }.sorted { $0.reference < $1.reference }
    }

    /// Disposes the process-local Cordis graph. Cordis owns idempotence, so a
    /// repeated shutdown is safe and does not rerun consumed cleanup effects.
    public func shutdown() async {
        // Close the wake path first so a late hint cannot start a
        // reconciliation pass against a disposing graph.
        await wakeObserver.stop()
        do {
            try await cordisContext.dispose()
        } catch {
            DebugLog.extraction("Process extraction context shutdown failed")
        }
    }
}
