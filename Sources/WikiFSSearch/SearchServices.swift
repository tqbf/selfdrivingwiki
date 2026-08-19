import Foundation

/// Consumer-facing search capability. Lifecycle and index mutation remain private
/// to the engine runtime that installs this facade.
public protocol SearchServices: Sendable {
    func search(
        query: String,
        kinds: [TantivyDocumentKind],
        limit: Int
    ) async throws -> [TantivyShadowSearchResult]

    func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult]
}

public extension SearchServices {
    func search(
        query: String,
        kinds: [TantivyDocumentKind] = [],
        limit: Int = 20
    ) async throws -> [TantivyShadowSearchResult] {
        try await search(query: query, kinds: kinds, limit: limit)
    }

    func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8 = 2,
        limit: Int = 8
    ) async throws -> [TantivyShadowSearchResult] {
        try await autocomplete(
            partial: partial,
            kinds: kinds,
            distance: distance,
            limit: limit)
    }
}

/// Stable failures that application boundaries can map to a missing BM25 leg.
public enum SearchServicesError: Error, Equatable, Sendable {
    case unavailable
    case disposedRuntime
    case invalidIdentity(String)
    case indexConstructionFailed(String)
    case startupFailed(String)
    case assemblyFailed(String)
}

public struct UnavailableSearchServices: SearchServices {
    public init() {}

    public func search(
        query: String,
        kinds: [TantivyDocumentKind],
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        throw SearchServicesError.unavailable
    }

    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        throw SearchServicesError.unavailable
    }
}

/// Stable actor facade used while asynchronous per-wiki assembly starts and stops.
public actor MutableSearchServices: SearchServices {
    public struct Installation: Hashable, Sendable {
        fileprivate let id = UUID()

        public init() {}
    }

    private var installed: any SearchServices
    private var activeInstallation: Installation?
    private var invalidatedInstallations: Set<Installation> = []

    public init(initial: any SearchServices = UnavailableSearchServices()) {
        installed = initial
    }

    public func install(
        _ services: any SearchServices,
        for installation: Installation
    ) {
        guard !invalidatedInstallations.contains(installation) else { return }
        installed = services
        activeInstallation = installation
    }

    public func invalidate(_ installation: Installation) {
        invalidatedInstallations.insert(installation)
        guard activeInstallation == installation else { return }
        installed = UnavailableSearchServices()
        activeInstallation = nil
    }

    public func search(
        query: String,
        kinds: [TantivyDocumentKind],
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try await installed.search(query: query, kinds: kinds, limit: limit)
    }

    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try await installed.autocomplete(
            partial: partial,
            kinds: kinds,
            distance: distance,
            limit: limit)
    }
}

#if os(macOS)
/// Query-only facade over one indexer. Runtime mutation APIs are intentionally
/// not exposed through `SearchServices`.
public struct IndexerSearchServices: SearchServices {
    private let indexer: TantivyIndexer

    public init(indexer: TantivyIndexer) {
        self.indexer = indexer
    }

    public func search(
        query: String,
        kinds: [TantivyDocumentKind],
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        guard !query.isEmpty, limit > 0 else { return [] }
        if kinds.count == 1, let only = kinds.first {
            return try await indexer.search(query: query, kind: only, limit: limit)
        }
        let raw = try await indexer.search(query: query, kind: nil, limit: limit)
        guard !kinds.isEmpty else { return raw }
        let allowed = Set(kinds)
        return raw.filter { allowed.contains($0.kind) }
    }

    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        guard !partial.isEmpty, !kinds.isEmpty, limit > 0 else { return [] }
        return try await indexer.autocomplete(
            partial: partial,
            kinds: kinds,
            distance: distance,
            limit: limit)
    }
}
#endif
