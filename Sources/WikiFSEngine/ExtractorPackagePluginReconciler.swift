import Cordis
import CordisLoader
import Foundation
import WikiFSCore

/// One package whose generated plugin failed to build or activate during
/// reconciliation. Messages are host-authored, bounded, and contain neither
/// paths nor environment details.
public struct ExtractorPackageReconciliationFailure: Sendable, Equatable {
    public let packageID: String
    public let version: String
    public let digestPrefix: String
    public let message: String

    init(revision: ExtractorPackageRevisionID, message: String) {
        packageID = revision.packageID.rawValue
        version = revision.version.rawValue
        digestPrefix = String(revision.digest.hex.prefix(12))
        self.message = Self.redact(message)
    }

    /// Keeps diagnostics bounded and free of incidental detail from thrown
    /// errors below the trusted factory boundary.
    static func redact(_ raw: String) -> String {
        let condensed = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(condensed.prefix(256))
    }
}

/// Result of applying one catalog generation to the dynamic plugin host.
public struct ExtractorPackageReconciliationReport: Sendable, Equatable {
    /// Generation observed from the authoritative catalog, or nil when the
    /// catalog could not be read.
    public let observedGeneration: UInt64?
    /// Generation applied before this report, or nil when application was
    /// skipped or failed.
    public let appliedGeneration: UInt64?
    public var skippedAsUnchanged: Bool
    public var registeredDefinitionIDs: [DynamicPluginDefinitionID]
    public var removedCount: Int
    public var failedPackages: [ExtractorPackageReconciliationFailure]

    init(
        observedGeneration: UInt64?,
        appliedGeneration: UInt64?,
        skippedAsUnchanged: Bool,
        registeredDefinitionIDs: [DynamicPluginDefinitionID],
        removedCount: Int,
        failedPackages: [ExtractorPackageReconciliationFailure]
    ) {
        self.observedGeneration = observedGeneration
        self.appliedGeneration = appliedGeneration
        self.skippedAsUnchanged = skippedAsUnchanged
        self.registeredDefinitionIDs = registeredDefinitionIDs
        self.removedCount = removedCount
        self.failedPackages = failedPackages
    }

    static func unchanged(_ generation: UInt64) -> Self {
        ExtractorPackageReconciliationReport(
            observedGeneration: generation,
            appliedGeneration: nil,
            skippedAsUnchanged: true,
            registeredDefinitionIDs: [],
            removedCount: 0,
            failedPackages: [])
    }

    static func unreadable() -> Self {
        ExtractorPackageReconciliationReport(
            observedGeneration: nil,
            appliedGeneration: nil,
            skippedAsUnchanged: false,
            registeredDefinitionIDs: [],
            removedCount: 0,
            failedPackages: [])
    }
}

/// Bridges durable machine-catalog generations into the process-local dynamic
/// plugin host. App and daemon contexts own separate reconcilers; wake inputs
/// are hints because every reconciliation reads an authoritative generation.
///
/// Per-revision isolation comes from the definitions themselves plus the
/// host's per-id lifecycle: one package that fails to build or validate never
/// blocks unrelated packages in the same pass.
public actor ExtractorPackagePluginReconciler {
    /// Bounded retention of reconciliation anomalies for inspection.
    static let maximumRetainedFailures = 32

    private let host: DynamicPluginHost
    private let catalogReader: any ExtractorPackageCatalogReading
    private let layout: ExtractorPackageStoreLayout
    private let sourceLocator: any ExtractorPackageSourceLocating
    private var lastAppliedGeneration: UInt64?
    private var retainedFailures: [ExtractorPackageReconciliationFailure] = []

    init(
        host: DynamicPluginHost,
        catalogReader: any ExtractorPackageCatalogReading,
        layout: ExtractorPackageStoreLayout,
        sourceLocator: (any ExtractorPackageSourceLocating)? = nil
    ) {
        self.host = host
        self.catalogReader = catalogReader
        self.layout = layout
        self.sourceLocator = sourceLocator
            ?? InstalledExtractorPackageSourceLocator(layout: layout)
    }

    /// Builds all definitions first so no lifecycle mutation happens when any
    /// manifest contradicts its catalog record.
    static func buildDesiredDefinitions(
        records: [ExtractorPackageCatalogRecord],
        sourceLocator: any ExtractorPackageSourceLocating
    ) -> (
        definitions: [TrustedDynamicPluginDefinition],
        failures: [ExtractorPackageReconciliationFailure]
    ) {
        var definitions: [TrustedDynamicPluginDefinition] = []
        var failures: [ExtractorPackageReconciliationFailure] = []
        definitions.reserveCapacity(records.count)
        for record in records.sorted() {
            do {
                // Full secure revalidation of exact installed bytes; also
                // guarantees manifest identity matches the catalog record.
                let source = sourceLocator.location(for: record.revision)
                let validated = try ExtractorDirectoryValidator.revalidate(
                    root: source.root,
                    within: source.containingRoot,
                    expectedRevision: record.revision)
                let definition = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
                    revision: record.revision,
                    manifest: validated.validated.manifest)
                definitions.append(definition)
            } catch {
                failures.append(ExtractorPackageReconciliationFailure(
                    revision: record.revision,
                    message: Self.failureMessage(error)))
            }
        }
        return (definitions, failures)
    }

    /// Applies the authoritative catalog generation. Unchanged generations are
    /// skipped unless forced; a corrupt or unreadable catalog keeps the current
    /// process graph untouched rather than tearing down known-good state.
    @discardableResult
    public func reconcileNow(force: Bool = false) async -> ExtractorPackageReconciliationReport {
        let catalog: ExtractorPackageCatalog
        do {
            catalog = try catalogReader.read()
        } catch {
            retain("catalog read failed; keeping current graph")
            return .unreadable()
        }
        if !force, let applied = lastAppliedGeneration, applied == catalog.generation {
            return .unchanged(catalog.generation)
        }

        let built = Self.buildDesiredDefinitions(
            records: catalog.records,
            sourceLocator: sourceLocator)
        retainEach(built.failures)

        do {
            let report = try await host.reconcile(desired: built.definitions)
            lastAppliedGeneration = catalog.generation
            retainNotices(for: report.operationFailures)
            return ExtractorPackageReconciliationReport(
                observedGeneration: catalog.generation,
                appliedGeneration: catalog.generation,
                skippedAsUnchanged: false,
                registeredDefinitionIDs: Array(report.outcomes.keys).sorted { $0.rawValue < $1.rawValue },
                removedCount: report.removedDefinitionIDs.count,
                failedPackages: built.failures + activateFailures(from: report))
        } catch {
            retain("host reconcile rejected generation \(catalog.generation)")
            return ExtractorPackageReconciliationReport(
                observedGeneration: catalog.generation,
                appliedGeneration: nil,
                skippedAsUnchanged: false,
                registeredDefinitionIDs: [],
                removedCount: 0,
                failedPackages: built.failures)
        }
    }

    /// Inspection snapshot for settings UI and diagnostics: what the durable
    /// catalog said versus what this process graph currently holds.
    public func observation() async -> (
        appliedGeneration: UInt64?,
        hostedPlugins: [DynamicPluginInspection],
        retainedFailures: [ExtractorPackageReconciliationFailure]
    ) {
        (
            lastAppliedGeneration,
            await host.inspectAll(),
            retainedFailures
        )
    }

    // MARK: - Failure plumbing

    private func retain(_ notice: String) {
        retainedFailures.append(ExtractorPackageReconciliationFailure(
            revision: ExtractorPackageRevisionID.placeholderForDiagnostic,
            message: notice))
        trimRetained()
    }

    private func retainEach(_ newFailures: [ExtractorPackageReconciliationFailure]) {
        retainedFailures.append(contentsOf: newFailures)
        trimRetained()
    }

    private func retainNotices(for operationFailures: [DynamicPluginDefinitionID: CordisFailure]) {
        guard operationFailures.isEmpty == false else { return }
        for (id, failure) in operationFailures.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            retainedFailures.append(ExtractorPackageReconciliationFailure(
                revision: ExtractorPackageRevisionID.placeholderForDiagnostic,
                message: "\(Self.shortDefinitionID(id)): \(failure.message)"))
        }
        trimRetained()
    }

    private func activateFailures(
        from report: DynamicPluginReconcileReport
    ) -> [ExtractorPackageReconciliationFailure] {
        report.outcomes.compactMap { id, outcome in
            guard case .failed(_, _, let phase, let failure) = outcome else { return nil }
            return ExtractorPackageReconciliationFailure(
                revision: .placeholderForDiagnostic,
                message: "\(Self.shortDefinitionID(id)): phase=\(phase.rawValue) \(failure.message)")
        }
    }

    private func trimRetained() {
        if retainedFailures.count > Self.maximumRetainedFailures {
            retainedFailures.removeFirst(retainedFailures.count - Self.maximumRetainedFailures)
        }
    }

    static func shortDefinitionID(_ id: DynamicPluginDefinitionID) -> String {
        String(id.rawValue.suffix(24))
    }

    static func failureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "package validation failed"
    }
}

private extension ExtractorPackageRevisionID {
    /// Reserved diagnostic-only placeholder for notices that are not tied to
    /// one package; the UI renders these as host notices, never as a package.
    /// The literal values are known-valid, so construction cannot fail.
    static let placeholderForDiagnostic: ExtractorPackageRevisionID = {
        do {
            return try ExtractorPackageRevisionID(
                packageID: ExtractorPackageID(validating: "org.wiki.host"),
                version: ExtractorPackageVersion(validating: "0.0.0"),
                digest: ExtractorSHA256.digest(Data()))
        } catch {
            preconditionFailure("Reserved diagnostic identity must be constructible")
        }
    }()
}
