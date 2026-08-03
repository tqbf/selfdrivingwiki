import Foundation

// MARK: - TantivyDocumentKind

/// The kind vocabulary for the shadow index. Independent of `ResourceKind`
/// (which lives in `WikiFSTypes`): this is the search module's own enum so the
/// FacetField value is always a well-formed hierarchical path (`"/page"`,
/// not `"page"`).
public enum TantivyDocumentKind: String, Sendable, CaseIterable {
    case page, source, chat

    /// The hierarchical facet path Tantivy expects (`"/page"`, `"/source"`,
    /// `"/chat"`). Tantivy facets use the leading-slash path convention.
    public var facetPath: String { "/\(rawValue)" }

    /// The `<kind>:` prefix used in the composite document id.
    public var idPrefix: String { "\(rawValue):" }

    /// Builds a composite document id: `"<kind>:<ULID>"`.
    public func documentID(for ulid: String) -> String { "\(idPrefix)\(ulid)" }
}

// MARK: - TantivyContentSnapshot

/// A neutral, plain value-type snapshot of one searchable resource. This is
/// the cross-module boundary between the store adapter (in `WikiFSCore`) and
/// the Tantivy indexer (in `WikiFSSearch`).
///
/// **Why this exists:** the actual Tantivy document (`TantivySearchDocument`,
/// an `@TantivyDocument` macro type) is `internal` to `WikiFSSearch` by design
/// (plans/tantivy-search-sidecar.md §8.1: "the store and model interact via the
/// search service's result types, not the raw Tantivy document"). The macro
/// generates an internal `CodingKeys`, so the document struct cannot be made
/// `public` without forking the upstream package. Instead, the store adapter
/// produces these plain snapshots and the indexer converts them to Tantivy
/// documents internally — keeping the Tantivy-specific schema an
/// implementation detail of the search module.
public struct TantivyContentSnapshot: Sendable, Equatable {
    public let ulid: String
    public let kind: TantivyDocumentKind
    public let title: String
    public let body: String
    public let updatedAt: Date
    public let versionSum: UInt64

    public init(
        ulid: String,
        kind: TantivyDocumentKind,
        title: String,
        body: String,
        updatedAt: Date,
        versionSum: UInt64
    ) {
        self.ulid = ulid
        self.kind = kind
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
        self.versionSum = versionSum
    }
}

// MARK: - TantivyContentSource

/// The protocol seam between the search module and the store.
///
/// `WikiFSSearch` depends only on `WikiFSTypes` — it cannot see `WikiEventBus`,
/// `ResourceChangeEvent`, or `WikiStore` (those live in `WikiFSCore`). Rather
/// than add a heavyweight dependency, the `TantivyIndexer` consumes abstract
/// `TantivyContentSnapshot`s produced by a concrete conforming type. The
/// concrete `StoreBackedTantivyContentSource` lives in `WikiFSCore` and reads
/// from `WikiStore`; it also subscribes to the event bus and forwards events
/// to the indexer. This keeps the search module reusable and testable in
/// isolation (plans/tantivy-search-sidecar.md §8.1).
///
/// All methods are `async throws` so a conforming store adapter can read
/// off-main (the store's `WikiReadPool`) without blocking the indexer actor.
public protocol TantivyContentSource: Sendable {
    /// Snapshot of a single resource, or `nil` if the resource no longer
    /// exists (already deleted upstream — the indexer treats `nil` as a
    /// delete).
    func snapshot(ulid: String, kind: TantivyDocumentKind) async throws -> TantivyContentSnapshot?

    /// Every snapshot in the source, for the initial full build / rebuild.
    func allSnapshots() async throws -> [TantivyContentSnapshot]
}

// MARK: - Public search result

/// A search hit returned by `TantivySearchService`. Decoupled from the raw
/// `TantivySearchResult<TantivySearchDocument>` so callers in `WikiFSCore` /
/// the app layer don't depend on the TantivySwift types directly.
public struct TantivyShadowSearchResult: Sendable, Equatable {
    public let documentID: String
    public let kind: TantivyDocumentKind
    public let title: String
    public let score: Float

    public init(documentID: String, kind: TantivyDocumentKind, title: String, score: Float) {
        self.documentID = documentID
        self.kind = kind
        self.title = title
        self.score = score
    }

    /// The raw ULID of the underlying resource, extracted from the composite
    /// `documentID` (`"<kind>:<ULID>"` — see `TantivyDocumentKind.documentID(for:)`).
    /// Empty when the prefix doesn't match (shouldn't happen for index-produced
    /// results), so callers can treat an empty ulid as "no resolvable id".
    ///
    /// Phase 2 uses this to map a Tantivy BM25 hit back to a typed store
    /// summary (`WikiPageSummary` / `SourceSummary` / `ChatSummary`) for the
    /// hybrid search's `bm25Leg`.
    public var ulid: String {
        let prefix = kind.idPrefix
        guard documentID.hasPrefix(prefix) else { return "" }
        return String(documentID.dropFirst(prefix.count))
    }
}
