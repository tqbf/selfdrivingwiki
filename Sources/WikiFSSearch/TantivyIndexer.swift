import Foundation
#if os(macOS)
import TantivySwift

// MARK: - TantivyIndexer

/// Actor that owns the on-disk `TantivySwiftIndex<TantivySearchDocument>` and
/// performs all index mutations + queries (plans/tantivy-search-sidecar.md §3).
///
/// **Concurrency model (SQLite discipline):** the actor holds only the
/// *Tantivy* index. It never touches SQLite directly. Reads of committed
/// state happen inside `TantivyContentSource` (the store adapter), off the
/// main actor; the Tantivy write happens here, on the actor's executor.
/// This respects "no inference/network inside a transaction" and "no
/// statement handle crossing a boundary" — the two concerns are on different
/// threads/locks entirely.
///
/// **Phase 1:** the indexer is built and kept up to date, but search results
/// are not surfaced to the user yet (FTS5 stays primary). The `search(...)`
/// method exists for shadow-mode validation and the smoke test.
public actor TantivyIndexer {
    /// The underlying Tantivy index. `nil` when the index failed to open or
    /// was marked for rebuild; callers degrade gracefully (shadow mode — a
    /// missing index just means no shadow results, FTS5 still answers).
    private var index: TantivySwiftIndex<TantivySearchDocument>?
    private let indexPath: String
    private let contentSource: any TantivyContentSource

    public init(indexDirectory: URL, contentSource: any TantivyContentSource) throws {
        let path = indexDirectory.path
        let fm = FileManager.default
        // Tantivy expects to create the directory itself; make sure the parent
        // exists so a fresh `<container>/search-index/<wikiID>/` path works
        // even when neither component exists yet.
        try fm.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        self.indexPath = path
        self.contentSource = contentSource

        do {
            self.index = try TantivySwiftIndex<TantivySearchDocument>(path: path)
        } catch {
            // Don't crash the app over a derived, rebuildable index. Log and
            // degrade; rebuildIndex() can retry. (Never use bare try? — see
            // project rules. This catch logs via DebugLog.store.)
            DebugLog.store("TantivyIndexer: failed to open index at \(path): \(error)")
            self.index = nil
        }
    }

    // MARK: - Mutations (driven by the event bus)

    /// Index (upsert) a single document by kind+ulid. Reads the current
    /// snapshot from the content source; if the source returns `nil`, the
    /// resource was deleted upstream and we delete it from the index too.
    public func upsert(ulid: String, kind: TantivyDocumentKind) async {
        guard let index else { return }
        do {
            if let snapshot = try await contentSource.snapshot(ulid: ulid, kind: kind) {
                try await index.index(doc: .from(snapshot))
            } else {
                // Already gone upstream — mirror the delete so the index
                // doesn't retain a stale doc.
                await delete(ulid: ulid, kind: kind)
            }
        } catch {
            DebugLog.store("TantivyIndexer: upsert(\(kind) \(ulid)) failed: \(error)")
        }
    }

    /// Remove a document from the index by kind+ulid.
    public func delete(ulid: String, kind: TantivyDocumentKind) async {
        guard let index else { return }
        let id = kind.documentID(for: ulid)
        do {
            try await index.deleteDoc(id: DocumentField(name: "id", value: .text(id)))
        } catch {
            DebugLog.store("TantivyIndexer: delete(\(kind) \(ulid)) failed: \(error)")
        }
    }

    /// Remove every document from the index (segment store is reset). Used by
    /// the rebuild path and the corruption self-heal.
    public func clear() async throws {
        guard let index else { return }
        try await index.clear()
    }

    // MARK: - Search

    /// Shadow-mode search. Returns hits for a free-text query, optionally
    /// restricted to one kind via the `kind` facet path.
    ///
    /// Uses `TantivySwiftSearchQuery` with `defaultFields` = title + body
    /// (both unicode-tokenized) and `fuzzyFields` for typo tolerance. The kind
    /// filter can't be expressed as a facet term clause on
    /// `TantivySwiftSearchQuery` (it has no facet clause field), so we
    /// over-fetch and post-filter by kind in Swift — the index is small in
    /// Phase 1. A Phase 2 optimization builds a `TantivyQuery.boolean` clause
    /// with a `.term` on the `kind` facet field so the engine filters before
    /// scoring/limit.
    public func search(query: String, kind: TantivyDocumentKind?, limit: Int) async throws -> [TantivyShadowSearchResult] {
        guard let index, !query.isEmpty else { return [] }
        let fetchLimit = kind == nil ? limit : limit * 5
        var q = TantivySwiftSearchQuery<TantivySearchDocument>(
            queryStr: query,
            defaultFields: [.title, .body],
            limit: UInt32(max(1, min(fetchLimit, 1_000)))
        )
        q.fuzzyFields = [
            .init(field: .title, prefix: true, distance: 1),
            .init(field: .body, prefix: false, distance: 1),
        ]
        let results = try await index.search(query: q)
        return Array(results.docs.compactMap { hit -> TantivyShadowSearchResult? in
            let kindEnum = TantivyDocumentKind.allCases.first { $0.facetPath == hit.doc.kind }
            guard let kindEnum else { return nil }
            if let kind, kindEnum != kind { return nil }
            return TantivyShadowSearchResult(
                documentID: hit.doc.id,
                kind: kindEnum,
                title: hit.doc.title,
                score: hit.score
            )
        }.prefix(limit))
    }

    // MARK: - Autocomplete (composer wiki-link fuzzy)

    /// Title-only fuzzy autocomplete scoped to one or more kinds. Used by the
    /// chat composer's `[[kind:partial` autocomplete (issues #436 / #638).
    ///
    /// **Reviewer correction #1 (load-bearing):** uses the **query-string path**
    /// (`TantivySwiftSearchQuery` + `TantivySwiftFuzzyField`), NOT the structured
    /// `TantivyQuery.fuzzy` enum. The structured `.fuzzy` case has no `prefix`
    /// parameter, and without `prefix: true` distance-2 fuzzy on a short
    /// partial like `"Erl"` will not surface `"Erickson"` (whole-token edit
    /// distance 6). The query-string path's `TantivySwiftFuzzyField` exposes
    /// both `distance: UInt8` AND `prefix: Bool` — this is the same path the
    /// shipped sidebar search uses (`search(query:kind:limit:)` above), with
    /// `distance: 2` instead of `1` and `prefix: true` on title only.
    ///
    /// Kind scoping is a **Swift post-filter** (same shape as `search()` at
    /// `:113-116`) since the query-string path carries no facet clause. The
    /// engine-level kind facet (`.term(.facet)` on `kind`) was a nice-to-have
    /// optimization dropped in review — it is not required by any AC.
    ///
    /// Title only (not body): the user is typing a title/name; body fuzzy
    /// would surface noise. distance 1–2 (default 2 — AC #638 headline case).
    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8 = 2,
        limit: Int = 8
    ) async throws -> [TantivyShadowSearchResult] {
        guard let index, !partial.isEmpty, !kinds.isEmpty else { return [] }
        // Over-fetch to give the Swift-side kind post-filter a fair pool to
        // draw from (same shape as `search()` `:102`). `min(limit*5, 1_000)`
        // matches the existing cap.
        let fetchLimit = max(1, min(limit * 5, 1_000))
        var q = TantivySwiftSearchQuery<TantivySearchDocument>(
            queryStr: partial,
            defaultFields: [.title],
            limit: UInt32(fetchLimit)
        )
        // prefix:true is load-bearing — see method doc and §3c nuance.
        q.fuzzyFields = [
            .init(field: .title, prefix: true, distance: distance),
        ]
        let results = try await index.search(query: q)
        let allowed = kinds
        return Array(results.docs.compactMap { hit -> TantivyShadowSearchResult? in
            let kindEnum = TantivyDocumentKind.allCases.first { $0.facetPath == hit.doc.kind }
            guard let kindEnum, allowed.contains(kindEnum) else { return nil }
            return TantivyShadowSearchResult(
                documentID: hit.doc.id,
                kind: kindEnum,
                title: hit.doc.title,
                score: hit.score
            )
        }.prefix(max(0, limit)))
    }

    // MARK: - Rebuild / initial build

    /// Number of indexed documents. Used by the service to detect an empty
    /// index that needs an initial build.
    public func count() async -> UInt64 {
        guard let index else { return 0 }
        return await index.count()
    }

    /// Full rebuild from the content source: clear, then index every snapshot
    /// in one batch commit. Used for the initial build and for crash-recovery
    /// self-heal (plans/tantivy-search-sidecar.md §3.3–§3.4).
    public func rebuild() async throws {
        // If the index never opened, retry once after deleting the (possibly
        // corrupt) on-disk directory. If reopen still fails, give up (shadow
        // mode — FTS5 still answers).
        if index == nil {
            try await reopen()
        }
        guard let index else { return }
        try await index.clear()
        let snapshots = try await contentSource.allSnapshots()
        if snapshots.isEmpty { return }
        // Batch index + single commit — far cheaper than N single-doc commits
        // (each single-doc index(doc:) auto-commits and creates a segment).
        let docs = snapshots.map(TantivySearchDocument.from)
        try await index.index(docs: docs)
    }

    // MARK: - Private

    /// Re-open the index after `index` was nilled (e.g. on open failure or
    /// corruption recovery). Deletes the on-disk directory first so a corrupt
    /// segment store can't poison the reopen.
    private func reopen() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: indexPath) {
            do {
                try fm.removeItem(atPath: indexPath)
            } catch {
                DebugLog.store("TantivyIndexer: could not remove corrupt index dir \(indexPath): \(error)")
            }
        }
        try fm.createDirectory(atPath: indexPath, withIntermediateDirectories: true)
        self.index = try TantivySwiftIndex<TantivySearchDocument>(path: indexPath)
    }
}
#endif // os(macOS)
