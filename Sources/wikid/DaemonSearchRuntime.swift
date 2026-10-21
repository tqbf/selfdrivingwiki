#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSSearch

// MARK: - Wire↔domain boundary helpers

/// Decodes wire values into typed daemon values. Raw kind strings never
/// travel past this boundary: `TantivyDocumentKind` from here on.
enum DaemonSearchWireMapping {
    /// `nil` or empty means "all kinds". Unknown kind strings are a request
    /// error, not a silent filter.
    static func kinds(_ raw: [String]?) throws -> Set<TantivyDocumentKind> {
        guard let raw, !raw.isEmpty else { return Set(TantivyDocumentKind.allCases) }
        var kinds = Set<TantivyDocumentKind>()
        for string in raw {
            guard let kind = TantivyDocumentKind(rawValue: string) else {
                throw DaemonSearchRequestError.unknownKind(string)
            }
            kinds.insert(kind)
        }
        return kinds
    }

    static func hits(_ results: [TantivyShadowSearchResult]) -> [SearchRPCHit] {
        results.map { result in
            SearchRPCHit(
                documentID: result.documentID,
                kind: result.kind.rawValue,
                title: result.title,
                score: Double(result.score))
        }
    }
}

/// Request-level failures that map to `SearchRPCErrorCode.invalidRequest`.
enum DaemonSearchRequestError: Error, Equatable {
    case unknownKind(String)

    var debugDescription: String {
        switch self {
        case .unknownKind(let kind):
            return "unknown search document kind: \(kind)"
        }
    }
}

// MARK: - DaemonSearchRuntime

/// Owns the wiki's persistent Tantivy writer at `search-index/<wikiID>`.
///
/// Each query compares the store's cross-process change token with the
/// baseline in `wiki_metadata`. A changed token or empty index requires a
/// rebuild through the existing writer. Empty wikis rebuild on each query.
/// The token is read before snapshot collection and persisted after commit,
/// so writes during a rebuild remain visible to the next query.
///
/// Serialization is a task chain, not bare actor isolation: actor reentrancy
/// would let a query interleave with an in-flight rebuild. Each operation
/// enqueues a typed task that awaits the previous tail first, so a query
/// during a rebuild waits for it instead of reading a partially rebuilt
/// index. `shutdown` stops admission, drains the chain, then releases the
/// indexer writer.
actor DaemonSearchRuntime {
    /// `wiki_metadata` key holding the change-token string the index was
    /// built against. `setMetadata` writes here are NO-EMIT (metadata does
    /// not change projected content) and the table is outside the change
    /// token's folds, so persisting the baseline never perturbs the token.
    static let baselineMetadataKey = "daemon.search.baselineToken"

    /// The sole index writer for this wiki. Optional so `shutdown` can
    /// release it once the chain drains instead of pinning it for the
    /// runtime object's remaining lifetime.
    private var indexer: TantivyIndexer?
    private let tokenReader: @Sendable () async throws -> String
    private let baselineReader: @Sendable () async throws -> String?
    private let baselineWriter: @Sendable (String) async throws -> Void

    private var chainTail: Task<Void, Never>?
    private var stopped = false
    /// Description of the most recent operation failure, for diagnostics.
    private(set) var lastFailureDescription: String?

    init(
        wikiID: WikiID,
        indexDirectory: URL,
        contentSource: any TantivyContentSource,
        tokenReader: @escaping @Sendable () async throws -> String,
        baselineReader: @escaping @Sendable () async throws -> String?,
        baselineWriter: @escaping @Sendable (String) async throws -> Void
    ) throws {
        self.indexer = try TantivyIndexer(
            indexDirectory: indexDirectory,
            contentSource: contentSource)
        self.tokenReader = tokenReader
        self.baselineReader = baselineReader
        self.baselineWriter = baselineWriter
    }

    // MARK: Queries

    func search(
        query: String,
        kinds: Set<TantivyDocumentKind>,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try await runChained { [weak self] indexer in
            guard let self else { throw DaemonSearchLifecycleError.stopped }
            try await self.synchronize(indexer)
            guard !query.isEmpty, limit > 0 else { return [] }
            return try await IndexerSearchServices(indexer: indexer)
                .search(query: query, kinds: Array(kinds), limit: limit)
        }
    }

    func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try await runChained { [weak self] indexer in
            guard let self else { throw DaemonSearchLifecycleError.stopped }
            try await self.synchronize(indexer)
            guard !partial.isEmpty, limit > 0 else { return [] }
            return try await IndexerSearchServices(indexer: indexer)
                .autocomplete(
                    partial: partial,
                    kinds: kinds,
                    distance: distance,
                    limit: limit)
        }
    }

    // MARK: Lifecycle

    /// Stops accepting new operations, waits for the in-flight chain to
    /// drain (in-flight rebuilds are never cancelled mid-write), then
    /// releases the indexer writer.
    func shutdown() async {
        stopped = true
        let tail = chainTail
        chainTail = nil
        await tail?.value
        indexer = nil
    }

    /// Test/diagnostic seam: whether the runtime still accepts operations.
    var isStopped: Bool { stopped }

    // MARK: Task chain (actor reentrancy cannot serialize awaits)

    /// Enqueues one operation behind every previously enqueued one. The
    /// operation's typed task awaits the prior tail BEFORE touching the
    /// actor, so chained work never interleaves; the caller awaits the
    /// operation directly. The tail bookkeeping task only observes the
    /// operation's completion so `shutdown` can drain. The body receives
    /// the indexer unwrapped on the actor (the body itself is not
    /// actor-isolated).
    private func runChained<T: Sendable>(
        _ body: @escaping @Sendable (TantivyIndexer) async throws -> T
    ) async throws -> T {
        if stopped { throw DaemonSearchLifecycleError.stopped }
        let prior = chainTail
        let operation = Task<T, Error> { [weak self] in
            guard let self else { throw DaemonSearchLifecycleError.stopped }
            await prior?.value
            return try await self.settle(body)
        }
        chainTail = Task { _ = await operation.result }
        return try await operation.value
    }

    /// Runs the chained body on the actor once every earlier operation has
    /// fully finished, handing it the sole writer. Failures are visible:
    /// logged once, surfaced to the caller, and never silently swallowed.
    private func settle<T: Sendable>(
        _ body: @escaping @Sendable (TantivyIndexer) async throws -> T
    ) async throws -> T {
        guard !stopped, let indexer else {
            throw DaemonSearchLifecycleError.stopped
        }
        do {
            let value = try await body(indexer)
            lastFailureDescription = nil
            return value
        } catch {
            lastFailureDescription = String(describing: error)
            DebugLog.store("wikid search: operation failed: \(error)")
            throw error
        }
    }

    // MARK: Freshness

    /// Catch up with committed store writes the index cannot see (external
    /// writers, writes while the daemon was down, or a deleted index
    /// directory). Baseline ordering: the token is read BEFORE the rebuild;
    /// persisting it after the rebuild commit cannot hide a mid-rebuild
    /// write, and a crash before the persist leaves a stale (older)
    /// baseline — one extra rebuild, never staleness.
    private func synchronize(_ indexer: TantivyIndexer) async throws {
        let baseline = try await baselineReader()
        let current = try await tokenReader()
        let indexedCount = await indexer.count()
        if baseline != current || indexedCount == 0 {
            if baseline != current {
                DebugLog.store("wikid search: store change token moved — rebuilding index")
            }
            try await indexer.rebuild()
            try await baselineWriter(current)
        }
    }
}

// MARK: - Errors

/// Lifecycle failures surfaced to the RPC boundary (mapped to
/// `SearchRPCErrorCode.unavailable`).
enum DaemonSearchLifecycleError: Error, Equatable {
    case stopped
}
#endif
