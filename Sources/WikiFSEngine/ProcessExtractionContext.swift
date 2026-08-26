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

    /// Assembles a fresh process context. Only this path may supply the five
    /// fixed services; consumers must use `cordisContext.require` equivalents
    /// via components, never supply competing values.
    public static func assemble(
        appGroupContainerRoot: URL,
        admissionOverride: (any ProcessPackageAdmissionChecking)? = nil,
        executor: any ManagedProcessExecuting = ManagedExtractorProcessExecutor()
    ) async throws -> ProcessExtractionContext {
        let layout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: appGroupContainerRoot,
            processRole: .app)
        return try await assemble(
            layout: layout,
            admissionOverride: admissionOverride,
            executor: executor)
    }

    /// Test-visible variant accepting an explicit role-scoped layout.
    public static func assemble(
        layout: ExtractorPackageStoreLayout,
        admissionOverride: (any ProcessPackageAdmissionChecking)? = nil,
        executor: any ManagedProcessExecuting = ManagedExtractorProcessExecutor()
    ) async throws -> ProcessExtractionContext {
        let cordisContext = CordisContext()
        let registry = ExtractionBackendRegistry()
        try await cordisContext.supply(ExtractionServiceKeys.backends, value: registry)
        try await cordisContext.supply(
            ExtractionServiceKeys.extractorCatalogReader,
            value: ExtractorPackageCatalogReader(layout: layout))
        try await cordisContext.supply(
            ExtractionServiceKeys.managedProcessExecutor,
            value: executor)
        try await cordisContext.supply(
            ExtractionServiceKeys.packageStoreLayout,
            value: layout)

        let host = DynamicPluginHost(context: cordisContext)
        let admission = admissionOverride ?? RegistryMembershipAdmission(registry: registry)
        try await cordisContext.supply(
            ExtractionServiceKeys.packageAdmissionChecker,
            value: admission)

        let reconciler = ExtractorPackagePluginReconciler(
            host: host,
            catalogReader: ExtractorPackageCatalogReader(layout: layout),
            layout: layout)
        return ProcessExtractionContext(
            cordisContext: cordisContext,
            registry: registry,
            host: host,
            reconciler: reconciler,
            layout: layout)
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
        retainedFailures: [ExtractorPackageReconciliationFailure]
    ) {
        await reconciler.observation()
    }
}
