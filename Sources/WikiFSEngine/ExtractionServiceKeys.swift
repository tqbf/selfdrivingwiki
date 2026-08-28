import Cordis
import Foundation
import WikiFSCore

/// The input domain handled by an extraction backend. The case tag keeps PDF,
/// HTML, and transcript backend identifiers in separate namespaces.
public enum ExtractionBackendKind: String, Codable, Hashable, Sendable {
    case pdf
    case html
    case youtubeTranscript
    case rssPodcastTranscript
    case applePodcastTranscript
}

/// Stable registry identity for one extraction adapter.
public struct ExtractionBackendKey: Hashable, Sendable, CustomStringConvertible {
    public let kind: ExtractionBackendKind
    public let backendID: String

    public init(kind: ExtractionBackendKind, backendID: String) {
        self.kind = kind
        self.backendID = backendID
    }

    public var description: String { "\(kind.rawValue)/\(backendID)" }
}

/// A lazily constructed adapter behind the shared extraction seam.
public enum ExtractionBackendAdapter: Sendable {
    case pdf(ExtractionPreparation)
    case html(any HtmlMarkdownExtractor)
    case youtubeTranscript(any YouTubeTranscriptFetching)
    case rssPodcastTranscript(any RSSFeedTranscriptFetching)
    case applePodcastTranscript(any PodcastTranscriptFetching)
}

public struct RegisteredExtractionBackend: Sendable {
    public typealias Factory = @Sendable () async throws -> ExtractionBackendAdapter

    public let key: ExtractionBackendKey
    private let makeAdapter: Factory

    public init(key: ExtractionBackendKey, makeAdapter: @escaping Factory) {
        self.key = key
        self.makeAdapter = makeAdapter
    }

    public func make() async throws -> ExtractionBackendAdapter {
        try await makeAdapter()
    }
}

public enum ExtractionBackendRegistryError: Error, Equatable, Sendable {
    case duplicateBackend(ExtractionBackendKey)
    case duplicateAdapter(ExtractionAdapterKey)
    case batchCollision([ExtractionAdapterKey])
}

/// Exact registry identity domain. Built-in adapters keep their legacy string
/// keys behind the `.builtIn` case; installed packages use exact revision and
/// registration references that cannot collide across versions or lineages.
public enum ExtractionAdapterKey: Hashable, Sendable, CustomStringConvertible {
    case builtIn(ExtractionBackendKey)
    case installed(kind: ExtractionBackendKind, reference: ExtractorReference)

    public var description: String {
        switch self {
        case .builtIn(let key):
            return key.description
        case .installed(let kind, let reference):
            return """
            \(kind.rawValue)/installed/\(reference.revision.packageID.rawValue)/\
            \(reference.revision.version.rawValue)/\(reference.revision.digest.hex.prefix(12))/\
            \(reference.registrationID.rawValue)
            """
        }
    }

    public var sortKey: String { description }
}

/// One resolved installed registration plus its exact key.
public struct InstalledExtractionMatch: Sendable {
    public let key: ExtractionAdapterKey
    public let backend: RegisteredExtractionBackend
}

/// One entry in an atomic multi-registration batch.
public struct ExtractionBatchEntry: Sendable {
    public let key: ExtractionAdapterKey
    public let backend: RegisteredExtractionBackend

    public init(key: ExtractionAdapterKey, backend: RegisteredExtractionBackend) {
        self.key = key
        self.backend = backend
    }
}

public struct ExtractionBackendBatchError: Error, Equatable, Sendable {
    public let collidingKeys: [ExtractionAdapterKey]
}

/// Token-owned handle over every registration committed by one batch. Disposal
/// removes exactly those entries; a stale disposal never touches a newer
/// registration even when keys match.
public struct ExtractionBackendBatchHandle: Sendable {
    // Sendability invariant: all fields are immutable after init; the only
    // shared mutable target is the weak actor reference, and calls into an
    // actor are safe from any thread. No lock is needed.
    // swiftlint:disable:next unchecked_sendable
    private struct Context: @unchecked Sendable {
        weak var registry: ExtractionBackendRegistry?
        let token: UUID
        let keys: [ExtractionAdapterKey]
    }

    private let context: Context

    fileprivate init(registry: ExtractionBackendRegistry, token: UUID, keys: [ExtractionAdapterKey]) {
        context = Context(registry: registry, token: token, keys: keys)
    }

    public func dispose() async {
        guard let registry = context.registry else { return }
        await registry.removeBatch(keys: context.keys, token: context.token)
    }
}

public struct ExtractionBackendRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped extraction adapter registry. Registration is reversible and
/// token-owned, so an old disposer cannot remove a later adapter with the same key.
public actor ExtractionBackendRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let backend: RegisteredExtractionBackend
    }

    private var registrations: [ExtractionAdapterKey: Registration] = [:]

    public init() {}

    /// Legacy built-in registration path used by static plugins.
    public func register(
        _ backend: RegisteredExtractionBackend
    ) throws -> ExtractionBackendRegistration {
        try register(backend, key: .builtIn(backend.key))
    }

    public func register(
        _ backend: RegisteredExtractionBackend,
        key: ExtractionAdapterKey
    ) throws -> ExtractionBackendRegistration {
        guard registrations[key] == nil else {
            throw ExtractionBackendRegistryError.duplicateAdapter(key)
        }
        let token = UUID()
        registrations[key] = Registration(token: token, backend: backend)
        return ExtractionBackendRegistration { [weak self] in
            await self?.remove(key: key, token: token)
        }
    }

    /// Validates every entry (including intra-batch collisions) before any
    /// mutation, then commits atomically under one shared token.
    public func registerBatch(
        _ entries: [ExtractionBatchEntry]
    ) throws -> ExtractionBackendBatchHandle {
        var incoming: [ExtractionAdapterKey: RegisteredExtractionBackend] = [:]
        for entry in entries {
            guard incoming[entry.key] == nil else {
                throw ExtractionBackendRegistryError.batchCollision([entry.key])
            }
            incoming[entry.key] = entry.backend
        }
        let colliding = entries.map(\.key).filter { registrations[$0] != nil }.sorted {
            $0.sortKey < $1.sortKey
        }
        if colliding.isEmpty == false {
            throw ExtractionBackendRegistryError.batchCollision(colliding)
        }
        let token = UUID()
        for (key, backend) in incoming {
            registrations[key] = Registration(token: token, backend: backend)
        }
        return ExtractionBackendBatchHandle(
            registry: self,
            token: token,
            keys: entries.map(\.key))
    }

    /// Highest compatible active exact registration for one logical selection:
    /// semantic version first, then exact revision identity. Install or
    /// activation order never matters.
    public func resolveInstalled(
        _ logical: LogicalExtractorReference,
        kind: ExtractionBackendKind
    ) -> InstalledExtractionMatch? {
        var bestKey: ExtractionAdapterKey?
        var bestReference: ExtractorReference?
        var bestBackend: RegisteredExtractionBackend?
        for (key, registration) in registrations {
            guard case .installed(let candidateKind, let reference) = key,
                  candidateKind == kind,
                  reference.registrationID == logical.registrationID,
                  reference.revision.packageID == logical.packageID else { continue }
            if let current = bestReference, reference <= current { continue }
            bestKey = key
            bestReference = reference
            bestBackend = registration.backend
        }
        guard let bestKey, let bestBackend else { return nil }
        return InstalledExtractionMatch(key: bestKey, backend: bestBackend)
    }

    /// Every active exact installed match for a kind, highest revision first.
    public func installedMatches(kind: ExtractionBackendKind) -> [InstalledExtractionMatch] {
        var matches: [(match: InstalledExtractionMatch, reference: ExtractorReference)] = []
        for (key, registration) in registrations {
            guard case .installed(let candidateKind, let reference) = key,
                  candidateKind == kind else { continue }
            matches.append((
                match: InstalledExtractionMatch(
                    key: key,
                    backend: registration.backend),
                reference: reference))
        }
        return matches
            .sorted { $0.reference > $1.reference }
            .map(\.match)
    }

    /// True when any active exact installation of this revision exists in
    /// either the PDF or HTML namespace. This is the admission authority for
    /// prepared operations: batch cleanup removes membership, so stale plugin
    /// definitions cannot admit removed code.
    public func containsRevision(_ revision: ExtractorPackageRevisionID) async -> Bool {
        for key in registrations.keys {
            guard case .installed(_, let reference) = key else { continue }
            if reference.revision == revision { return true }
        }
        return false
    }

    public func resolve(_ key: ExtractionBackendKey) -> RegisteredExtractionBackend? {
        resolve(.builtIn(key))
    }

    public func resolve(_ key: ExtractionAdapterKey) -> RegisteredExtractionBackend? {
        registrations[key]?.backend
    }

    /// Legacy view over the built-in namespace only.
    public func keys() -> [ExtractionBackendKey] {
        registrations.keys.compactMap {
            if case .builtIn(let key) = $0 { return key }
            return nil
        }
        .sorted { $0.description < $1.description }
    }

    public func allKeys() -> [ExtractionAdapterKey] {
        registrations.keys.sorted { $0.sortKey < $1.sortKey }
    }

    private func remove(key: ExtractionAdapterKey, token: UUID) {
        guard registrations[key]?.token == token else { return }
        registrations.removeValue(forKey: key)
    }

    fileprivate func removeBatch(keys: [ExtractionAdapterKey], token: UUID) {
        for key in keys {
            guard registrations[key]?.token == token else { continue }
            registrations.removeValue(forKey: key)
        }
    }
}

/// One installed (exact) extraction package registration as shown in
/// Settings → Extraction. A read-only lifecycle surface: the registry's active
/// exact registrations presented with user-facing terms. Built-in adapters are
/// not rows — the backend picker owns those.
public struct ExtractorPackageSettingsRow: Identifiable, Hashable, Sendable {
    public let kind: ExtractionBackendKind
    public let packageID: String
    public let version: String
    /// First 12 hex characters of the pinned revision digest — enough to
    /// identify the exact bytes without exposing a full path or payload.
    public let digestPrefix: String
    public let registrationID: String
    /// The exact installed revision. Removal targets revisions (the catalog's
    /// lifecycle granularity), not registrations.
    public let revision: ExtractorPackageRevisionID

    public init(
        kind: ExtractionBackendKind,
        packageID: String,
        version: String,
        digestPrefix: String,
        registrationID: String,
        revision: ExtractorPackageRevisionID
    ) {
        self.kind = kind
        self.packageID = packageID
        self.version = version
        self.digestPrefix = digestPrefix
        self.registrationID = registrationID
        self.revision = revision
    }

    public var id: String {
        "\(kind.rawValue)/\(packageID)/\(version)/\(digestPrefix)/\(registrationID)"
    }
}

public extension ExtractionBackendRegistry {
    /// Snapshot of every active installed (exact) PDF and HTML registration,
    /// highest revision first within a deterministic package sort. Transcript
    /// kinds are out of scope for revision 1. A package that stopped being
    /// admitted (removed, failed activation) simply stops appearing.
    func installedPackageRows() async -> [ExtractorPackageSettingsRow] {
        var rows: [ExtractorPackageSettingsRow] = []
        for kind in [ExtractionBackendKind.pdf, .html] {
            // Actor-isolated by default (extension of an actor), so the sync
            // registry read needs no hop.
            for match in installedMatches(kind: kind) {
                guard case .installed(_, let reference) = match.key else { continue }
                rows.append(ExtractorPackageSettingsRow(
                    kind: kind,
                    packageID: reference.revision.packageID.rawValue,
                    version: reference.revision.version.rawValue,
                    digestPrefix: String(reference.revision.digest.hex.prefix(12)),
                    registrationID: reference.registrationID.rawValue,
                    revision: reference.revision))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }
}

public enum ExtractionServiceKeys {
    public static let backends = ServiceKey<ExtractionBackendRegistry>(label: "wiki.extraction")

    /// Fixed host-owned dependencies for generated package plugins. A manifest
    /// cannot request anything outside this contract.
    public static let extractorCatalogReader = ServiceKey<any ExtractorPackageCatalogReading>(
        label: "wiki.extraction.catalog-reader")
    public static let managedProcessExecutor = ServiceKey<any ManagedProcessExecuting>(
        label: "wiki.extraction.process-executor")
    public static let packageAdmissionChecker = ServiceKey<any ProcessPackageAdmissionChecking>(
        label: "wiki.extraction.admission-checker")
    public static let packageStoreLayout = ServiceKey<ExtractorPackageStoreLayout>(
        label: "wiki.extraction.store-layout")
    /// Resolves the exact bytes of one revision for this process. Installed
    /// revisions resolve to the store; reviewed bundled revisions resolve to
    /// the process-owned admitted copy.
    public static let packageSourceLocator = ServiceKey<any ExtractorPackageSourceLocating>(
        label: "wiki.extraction.package-source-locator")
}
