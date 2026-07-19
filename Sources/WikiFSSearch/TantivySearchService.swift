import Foundation

// MARK: - TantivySearchService

/// Owns the `TantivyIndexer` actor and the per-wiki lifecycle of the on-disk
/// Tantivy shadow index (plans/tantivy-search-sidecar.md §3.3–§3.4, §6.2).
///
/// **Index location** (§6.2): `<appGroupContainer>/search-index/<wikiID>/`.
/// The index is a derived artifact — SQLite is always the source of truth —
/// so any corruption is recovered by a full rebuild from the content source.
///
/// **Phase 1:** this service is EXPERIMENTAL. It builds and maintains the
/// index in shadow mode (FTS5 remains the primary search path). Callers
/// should not surface `search(...)` results to the user yet — use it only for
/// validation / the smoke test.
public final class TantivySearchService: Sendable {
    public let indexer: TantivyIndexer
    public let wikiID: String
    private let indexDirectory: URL

    public init(wikiID: String, containerDirectory: URL, contentSource: any TantivyContentSource) throws {
        self.wikiID = wikiID
        // `<container>/search-index/<wikiID>/` — per-wiki, alongside the
        // `.sqlite` files (same TCC-protected container the app already
        // owns, so no extra entitlement work).
        let dir = containerDirectory
            .appendingPathComponent("search-index", isDirectory: true)
            .appendingPathComponent(wikiID, isDirectory: true)
        self.indexDirectory = dir
        self.indexer = try TantivyIndexer(indexDirectory: dir, contentSource: contentSource)
    }

    // MARK: - Shadow-mode search

    /// Free-text search over the Tantivy index, optionally restricted to one
    /// kind. Returns empty on any error (the caller falls back to FTS5 in
    /// Phase 2; in Phase 1 the result is logged for comparison, not shown).
    public func search(query: String, kinds: [TantivyDocumentKind] = [], limit: Int = 20) async -> [TantivyShadowSearchResult] {
        do {
            // Single-kind fast path: ask the indexer to filter.
            if kinds.count == 1, let only = kinds.first {
                return try await indexer.search(query: query, kind: only, limit: limit)
            }
            // No filter, or multi-kind: query unfiltered then post-filter to
            // the allowed kinds. (Phase 1 indexes are small; a Phase 2
            // boolean query removes this.)
            let raw = try await indexer.search(query: query, kind: nil, limit: limit)
            if kinds.isEmpty { return raw }
            let allowed = Set(kinds)
            return raw.filter { allowed.contains($0.kind) }
        } catch {
            DebugLog.store("TantivySearchService: search(\"\(query)\") failed: \(error)")
            return []
        }
    }

    // MARK: - Autocomplete (composer wiki-link fuzzy)

    /// Title-only fuzzy autocomplete scoped to one or more kinds. Drives the
    /// chat composer's `[[kind:partial` autocomplete (issues #436 / #638).
    /// Returns empty on any error (never throws — autocomplete is best-effort).
    ///
    /// Defaults: distance 2, limit 8. `kinds` is a Set so the composer can
    /// pre-scope to one kind (`[[page:` → `[.page]`) or open it up later.
    /// See `TantivyIndexer.autocomplete(...)` for the query-string-path
    /// rationale (prefix-true on title is load-bearing for the
    /// `"Erl" → "Erickson"` headline case).
    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8 = 2,
        limit: Int = 8
    ) async -> [TantivyShadowSearchResult] {
        do {
            return try await indexer.autocomplete(
                partial: partial, kinds: kinds, distance: distance, limit: limit)
        } catch {
            DebugLog.store("TantivySearchService: autocomplete(\"\(partial)\") failed: \(error)")
            return []
        }
    }

    // MARK: - Lifecycle

    /// Ensure the shadow index is populated. On first open (empty index) or
    /// after corruption, run a full rebuild from the content source. Safe to
    /// call on every wiki open — it short-circuits when the index already has
    /// documents.
    ///
    /// **Concurrency:** runs on a detached task so the wiki open path is not
    /// blocked by a potentially large initial build. `await`-free on the
    /// caller; callers that need the build complete can `await rebuildIfNeeded()`.
    public func rebuildIfNeeded() async {
        do {
            let n = await indexer.count()
            if n == 0 {
                DebugLog.store("TantivySearchService[\(wikiID)]: index empty — rebuilding from store")
                try await indexer.rebuild()
                let after = await indexer.count()
                DebugLog.store("TantivySearchService[\(wikiID)]: rebuild complete (\(after) docs)")
            }
        } catch {
            DebugLog.store("TantivySearchService[\(wikiID)]: rebuild failed: \(error)")
        }
    }

    /// Force a full rebuild (used after corruption detection or an external
    /// coarse `.external` event where we can't tell what changed).
    public func rebuild() async {
        do {
            try await indexer.rebuild()
        } catch {
            DebugLog.store("TantivySearchService[\(wikiID)]: forced rebuild failed: \(error)")
        }
    }

    /// Delete the on-disk index entirely (wiki removal path). Best-effort —
    /// a leftover dir is rebuilt-from-scratch-safe since SQLite is the source
    /// of truth.
    public func deleteIndex() {
        let fm = FileManager.default
        if fm.fileExists(atPath: indexDirectory.path) {
            do {
                try fm.removeItem(at: indexDirectory)
            } catch {
                DebugLog.store("TantivySearchService[\(wikiID)]: could not delete index dir: \(error)")
            }
        }
    }
}
