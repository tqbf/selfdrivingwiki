import Foundation
#if os(macOS)
import TantivySwift

// MARK: - TantivySearchDocument (internal — Tantivy-specific schema)

/// The single Tantivy index document for the Phase 1 shadow index
/// (plans/tantivy-search-sidecar.md §2.2).
///
/// Internal to `WikiFSSearch` — the macro-generated `CodingKeys` is internal
/// (the upstream `@TantivyDocument` macro doesn't emit `public`), so the store
/// adapter instead produces `TantivyContentSnapshot`s and the indexer converts
/// them here. One unified index holds every searchable resource — pages,
/// sources, and chats — distinguished by the `kind` facet field. The `id` is
/// `"<kind>:<ULID>"` so it is globally unique *across kinds in the same
/// index*, which is what Tantivy's `deleteDoc(id:)` matches against.
///
/// **Phase 1 only.** Tantivy BM25 + Swift cosine (`VectorCosine`) + RRF is the
/// primary search path.
///
/// macOS-only: the `@TantivyDocument` macro + TantivySwift are unavailable on
/// Linux (#754). The portable value types (`TantivyDocumentKind`,
/// `TantivyContentSnapshot`, `TantivyContentSource`,
/// `TantivyShadowSearchResult`) live in `TantivySearchTypes.swift`.
@TantivyDocument
struct TantivySearchDocument: Sendable {
    /// `"<kind>:<ULID>"` — globally unique within the single index.
    @IDField var id: String
    /// `page.title` | `source.effectiveName` | `chat.title`.
    @TextField var title: String
    /// `page.bodyMarkdown` | `source` processed markdown HEAD |
    /// concatenated chat message plain text.
    @TextField var body: String
    /// Facet path: `"/page"` | `"/source"` | `"/chat"`.
    @FacetField var kind: String
    /// Last modification time of the underlying resource.
    @DateField var updatedAt: Date
    /// `source.version`, or the page/chat version, for staleness detection.
    @U64Field var versionSum: UInt64

    init(
        id: String,
        title: String,
        body: String,
        kind: String,
        updatedAt: Date,
        versionSum: UInt64
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.updatedAt = updatedAt
        self.versionSum = versionSum
    }
}

extension TantivySearchDocument {
    /// Convert a neutral store snapshot into the Tantivy schema document.
    static func from(_ snapshot: TantivyContentSnapshot) -> TantivySearchDocument {
        TantivySearchDocument(
            id: snapshot.kind.documentID(for: snapshot.ulid),
            title: snapshot.title,
            body: snapshot.body,
            kind: snapshot.kind.facetPath,
            updatedAt: snapshot.updatedAt,
            versionSum: snapshot.versionSum
        )
    }
}

#endif // os(macOS)
