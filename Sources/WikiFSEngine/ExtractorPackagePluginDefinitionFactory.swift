import Cordis
import CordisLoader
import Foundation
import WikiFSCore

/// Host-generated trusted definitions for installed extractor package
/// revisions. One exact revision maps to one deterministic plugin identity;
/// every activation builds a fresh component. The definition carries only the
/// fixed host dependency contract and contributes only extractor batch
/// registrations — never tools, events, listeners, or arbitrary services.
public enum ExtractorPackagePluginDefinitionFactory {
    public enum FactoryError: Error, Equatable, LocalizedError {
        case unsupportedProtocol(ExtractorProtocolRevision)
        case unsupportedRegistrationKind(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedProtocol(let revision):
                return "Package protocol revision \(revision.rawValue) is not supported."
            case .unsupportedRegistrationKind(let kind):
                return "Package registers an unsupported extractor kind: \(kind)."
            }
        }
    }

    /// Stable Cordis identity for one revision. Raw external package IDs stay
    /// out of the encoding; identity derives from a digest of the canonical
    /// revision tuple.
    public static func pluginID(for revision: ExtractorPackageRevisionID) -> PluginID {
        PluginID("dynamic:extractor-package/" + Self.identityDigest(revision, protocolRevision: nil))
    }

    /// Immutable fingerprint over everything this definition's behavior
    /// depends on: exact revision, supported protocol, normalized
    /// registrations, and the fixed dependency contract version.
    public static func fingerprint(
        for manifest: ExtractorManifest,
        revision: ExtractorPackageRevisionID,
        dependencyContractVersion: Int = 2
    ) throws -> DynamicPluginDefinitionFingerprint {
        try validate(manifest)
        let registrationDescription = manifest.registrations
            .sorted()
            .map { registration -> String in
                let kinds = registration.kinds.map(\.rawValue).sorted().joined(separator: ",")
                let mimeTypes = registration.mimeTypes.map(\.rawValue).sorted().joined(separator: ",")
                return "\(registration.id.rawValue)|\(kinds)|\(mimeTypes)"
            }
            .joined(separator: ";")
        let canonical = """
        v\(dependencyContractVersion)/\
        \(revision.packageID.rawValue)/\
        \(revision.version.rawValue)/\
        \(revision.digest.hex)/\
        proto:\(manifest.protocolRevision.rawValue)/\
        regs:\(registrationDescription)
        """
        return DynamicPluginDefinitionFingerprint(canonical.sha256Hex)
    }

    /// Builds one trusted definition after cheap revalidation of identity.
    /// Activation starts no script; heavy snapshot work stays inside the
    /// Phase 4b provider at preparation time.
    public static func trustedDefinition(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) throws -> TrustedDynamicPluginDefinition {
        guard revision.packageID == manifest.packageID,
              revision.version == manifest.version else {
            throw ProcessPackagePreparationError.identityMismatch
        }
        do {
            guard try manifest.packageDigest() == revision.digest else {
                throw ProcessPackagePreparationError.identityMismatch
            }
        } catch let error as ProcessPackagePreparationError {
            throw error
        } catch {
            throw ProcessPackagePreparationError.identityMismatch
        }
        try validate(manifest)
        let dependencies = [
            ServiceDependency(ExtractionServiceKeys.backends),
            ServiceDependency(ExtractionServiceKeys.extractorCatalogReader),
            ServiceDependency(ExtractionServiceKeys.managedProcessExecutor),
            ServiceDependency(ExtractionServiceKeys.packageAdmissionChecker),
            ServiceDependency(ExtractionServiceKeys.packageStoreLayout),
            ServiceDependency(ExtractionServiceKeys.packageSourceLocator),
        ]
        let fingerprint = try self.fingerprint(for: manifest, revision: revision)
        let id = DynamicPluginDefinitionID("extractor-package/" + Self.identityDigest(
            revision,
            protocolRevision: manifest.protocolRevision.rawValue))
        let capturedRevision = revision
        let capturedManifest = manifest
        let plugin = PluginDefinition(
            id: PluginID(id.rawValue),
            label: "Installed extractor \(manifest.displayName)",
            dependencies: dependencies
        ) {
            try Self.makeComponentDefinition(
                revision: capturedRevision,
                manifest: capturedManifest)
        }
        // Declared reversible work: one atomic batch commit plus its cleanup
        // effect. Registration factories themselves are pure closures.
        return TrustedDynamicPluginDefinition(
            id: id,
            fingerprint: fingerprint,
            plugin: plugin,
            declaredWorkCount: 1)
    }

    // MARK: - Component body

    static func makeComponentDefinition(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) throws -> ComponentDefinition {
        try ComponentDefinition(
            label: "extractor-package/\(revision.digest.hex.prefix(12))",
            dependencies: [
                ServiceDependency(ExtractionServiceKeys.backends),
                ServiceDependency(ExtractionServiceKeys.extractorCatalogReader),
                ServiceDependency(ExtractionServiceKeys.managedProcessExecutor),
                ServiceDependency(ExtractionServiceKeys.packageAdmissionChecker),
                ServiceDependency(ExtractionServiceKeys.packageStoreLayout),
                ServiceDependency(ExtractionServiceKeys.packageSourceLocator),
            ]
        ) { activation in
            let registry = try await activation.require(ExtractionServiceKeys.backends)

            // Cheap authoritative revalidation before any mutation. Snapshots
            // are taken later, per prepared operation.
            let catalogReader = try await activation.require(
                ExtractionServiceKeys.extractorCatalogReader)
            let catalog = try catalogReader.read()
            guard catalog.records.contains(where: { $0.revision == revision }) else {
                throw ProcessPackagePreparationError.unknownRevision
            }

            let layout = try await activation.require(ExtractionServiceKeys.packageStoreLayout)
            let executor = try await activation.require(ExtractionServiceKeys.managedProcessExecutor)
            let admissionChecker = try await activation.require(
                ExtractionServiceKeys.packageAdmissionChecker)
            let sourceLocator = try await activation.require(
                ExtractionServiceKeys.packageSourceLocator)
            let provider = ProcessExtractorProvider(
                layout: layout,
                catalogReader: catalogReader,
                executor: executor,
                admission: admissionChecker,
                sourceLocator: sourceLocator,
                sharedRuntimeCacheRoot: layout.root.appendingPathComponent("runtime-cache", isDirectory: true),
                sharedModelCacheRoot: layout.root.appendingPathComponent("model-cache", isDirectory: true))

            // Build every registration factory before mutating the registry.
            var entries: [ExtractionBatchEntry] = []
            entries.reserveCapacity(manifest.registrations.count)
            for registration in manifest.registrations.sorted() {
                let kinds = registration.kinds
                    .sorted { $0.rawValue < $1.rawValue }
                for kind in kinds {
                    guard let backendKind = backendKind(for: kind) else {
                        throw FactoryError.unsupportedRegistrationKind(kind.rawValue)
                    }
                    let reference = ExtractorReference(
                        revision: revision,
                        registrationID: registration.id)
                    switch kind {
                    case .pdf:
                        entries.append(ExtractionBatchEntry(
                            key: .installed(kind: backendKind, reference: reference),
                            backend: RegisteredExtractionBackend(key: legacyPlaceholderKey) {
                                let preparation = try await provider.preparePDF(
                                    revision: revision,
                                    manifest: manifest)
                                return ExtractionBackendAdapter.pdf(preparation)
                            }))
                    case .html:
                        entries.append(ExtractionBatchEntry(
                            key: .installed(kind: backendKind, reference: reference),
                            backend: RegisteredExtractionBackend(key: legacyPlaceholderKey) {
                                let html = try await provider.prepareHTML(
                                    revision: revision,
                                    manifest: manifest)
                                return ExtractionBackendAdapter.html(html)
                            }))
                    }
                }
            }

            let batch = try await registry.registerBatch(entries)
            _ = try await activation.effect { _ in
                await batch.dispose()
            }
        }
    }

    private static func backendKind(
        for kind: ExtractorKind
    ) -> ExtractionBackendKind? {
        switch kind {
        case .pdf: return .pdf
        case .html: return .html
        }
    }

    private static func validate(_ manifest: ExtractorManifest) throws {
        guard manifest.protocolRevision == .v1 else {
            throw FactoryError.unsupportedProtocol(manifest.protocolRevision)
        }
        for registration in manifest.registrations {
            guard registration.kinds.isSubset(of: [.pdf, .html]) else {
                let offending = registration.kinds.subtracting([.pdf, .html]).first.map(\.rawValue) ?? "?"
                throw FactoryError.unsupportedRegistrationKind(offending)
            }
        }
    }

    private static func identityDigest(
        _ revision: ExtractorPackageRevisionID,
        protocolRevision: Int?
    ) -> String {
        let canonical = """
        extractor-package/\(revision.packageID.rawValue)/\
        \(revision.version.rawValue)/\
        \(revision.digest.hex)\(protocolRevision.map { "/proto:\($0)" } ?? "")
        """
        return String(canonical.sha256Hex.prefix(identityDigestLength))
    }

    private static let identityDigestLength = 32
    private static let legacyPlaceholderKey = ExtractionBackendKey(kind: .pdf, backendID: "placeholder")
}

extension String {
    fileprivate var sha256Hex: String {
        ExtractorSHA256.digest(Data(utf8)).hex
    }
}
