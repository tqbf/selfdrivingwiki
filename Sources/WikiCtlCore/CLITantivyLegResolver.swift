import Foundation
import WikiFSCore

/// Bridges the wikictl CLI's three search commands (`page search`,
/// `source search`, `chat search`) onto the SAME Tantivy BM25 leg the app's
/// sidebar / omnibox use (#637).
///
/// wikictl opens a `GRDBWikiStore` directly and prior to #637 called the
/// 2-arg `store.searchSimilar(query:limit:)` overloads, which forward to the
/// 3-arg path with `bm25Leg: nil` — meaning the store ran its OWN FTS5 leg
/// (now history: #634 dropped FTS5) and never queried the on-disk Tantivy
/// index at `<appGroupContainer>/search-index/<wikiID>/`. That bypassed the
/// Tantivy `fuzzyFields` (edit-distance 1 on title + body, already
/// configured at `Sources/WikiFSSearch/TantivyIndexer.swift:108-111`) and
/// post-#634 means `bm25Leg: nil` has NO BM25 leg at all (cosine-only, empty
/// under `swift test` where NLEmbedding is app-gated).
///
/// This resolver constructs a CLI-owned `TantivySearchService` over the SAME
/// on-disk index the app builds/maintains (the index is a derived artifact, so
/// concurrently opening it read-only is safe — SQLite remains the source of
/// truth), runs the kind-scoped search via the actor (bridged async→sync with
/// a semaphore, mirroring `wikid`'s `runRefresh` pattern), and resolves the
/// hits to typed summaries (`WikiPageSummary` / `SourceSummary` / `ChatSummary`)
/// via the store's list APIs — preserving Tantivy's best-first rank order, the
/// same mapping `WikiStoreModel.resolveTantivyLeg(query:kind:limit:catalog:)`
/// performs for the sidebar.
///
/// Returns `nil` when Tantivy is unavailable, the index returned nothing, or
/// every hit was missing from the catalog. Post-#634, `nil` means "no BM25
/// leg" — the store's FTS5 fallback was dropped (#634); the cosine leg still
/// answers when NLEmbedding/MLX and vec are available. As long as the wiki
/// has been opened in the app at least once (the app kicks off the initial
/// build via `TantivyShadowSync.start()`), the Tantivy leg is populated.
public enum CLITantivyLegResolver {

    /// Resolve a Tantivy BM25 leg for `wikictl page search`. Returns `nil`
    /// when the index is unavailable/empty — post-#634 that means no BM25
    /// leg (FTS5 was dropped in #634; the cosine leg still answers when
    /// NLEmbedding/vec are available).
    public static func resolvePageLeg(
        wikiID: String,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        limit: Int
    ) -> [WikiPageSummary]? {
        guard let svc = makeService(wikiID: wikiID, containerDirectory: containerDirectory, store: store) else {
            return nil
        }
        let hits = runSearch(svc: svc, query: query, kind: .page, limit: limit)
        guard !hits.isEmpty else { return nil }
        let catalog: [WikiPageSummary]
        do {
            catalog = try store.listPages(sortBy: .lastUpdated)
        } catch {
            DebugLog.store("wikictl: listPages(leg) failed for wiki \(wikiID): \(error)")
            return nil
        }
        return resolveHits(hits, catalog: catalog)
    }

    /// Resolve a Tantivy BM25 leg for `wikictl source search`. Same contract
    /// as ``resolvePageLeg(wikiID:containerDirectory:store:query:limit:)``.
    public static func resolveSourceLeg(
        wikiID: String,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        limit: Int
    ) -> [SourceSummary]? {
        guard let svc = makeService(wikiID: wikiID, containerDirectory: containerDirectory, store: store) else {
            return nil
        }
        let hits = runSearch(svc: svc, query: query, kind: .source, limit: limit)
        guard !hits.isEmpty else { return nil }
        let catalog: [SourceSummary]
        do {
            catalog = try store.listSources()
        } catch {
            DebugLog.store("wikictl: listSources(leg) failed for wiki \(wikiID): \(error)")
            return nil
        }
        return resolveHits(hits, catalog: catalog)
    }

    /// Resolve a Tantivy BM25 leg for `wikictl chat search`. Same contract as
    /// ``resolvePageLeg(wikiID:containerDirectory:store:query:limit:)``.
    public static func resolveChatLeg(
        wikiID: String,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        limit: Int
    ) -> [ChatSummary]? {
        guard let svc = makeService(wikiID: wikiID, containerDirectory: containerDirectory, store: store) else {
            return nil
        }
        let hits = runSearch(svc: svc, query: query, kind: .chat, limit: limit)
        guard !hits.isEmpty else { return nil }
        let catalog: [ChatSummary]
        do {
            catalog = try store.listChats()
        } catch {
            DebugLog.store("wikictl: listChats(leg) failed for wiki \(wikiID): \(error)")
            return nil
        }
        return resolveHits(hits, catalog: catalog)
    }

    // MARK: - Internal

    /// Construct a CLI-owned `TantivySearchService` over the same on-disk
    /// index the app builds/maintains. `nil` (not an error) when the index
    /// can't be opened — failures are logged via `DebugLog.store` so they're
    /// visible in Console.app even from the CLI invocation.
    private static func makeService(
        wikiID: String,
        containerDirectory: URL,
        store: WikiStore
    ) -> TantivySearchService? {
        let contentSource = StoreBackedTantivyContentSource(store: store)
        do {
            return try TantivySearchService(
                wikiID: wikiID,
                containerDirectory: containerDirectory,
                contentSource: contentSource
            )
        } catch {
            DebugLog.store("wikictl: Tantivy search index unavailable for wiki \(wikiID): \(error)")
            return nil
        }
    }

    /// Bridge `TantivySearchService.search` to synchronous execution, mirroring
    /// `wikictl`'s existing `runRefresh` async→sync semaphore pattern at
    /// `Sources/wikictl/main.swift:180-200`. Safe because the search runs on
    /// the `TantivyIndexer` actor (off-main); the dispatched `Task` signals
    /// the semaphore from a thread that never needs the main thread.
    ///
    /// Calls `rebuildIfNeeded()` before querying — opening a fresh
    /// `TantivySearchService` against an existing on-disk index can initially
    /// report `count == 0` until the rebuild path runs (the index open seems
    /// to need a kick for the in-memory state to reflect disk). The rebuild
    /// is itself a no-op when the index already has documents (a single
    /// `count()` call short-circuits) — so the steady-state cost is one
    /// `count()` per CLI search invocation. When the index is empty or
    /// missing (the wiki has been used via `wikictl` but never opened in the
    /// app, so `TantivyShadowSync.start()` never ran), this is what surfaces
    /// the content.
    private static func runSearch(
        svc: TantivySearchService,
        query: String,
        kind: TantivyDocumentKind,
        limit: Int
    ) -> [TantivyShadowSearchResult] {
        let box = SearchBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            // Mirror TantivyShadowSync.start()'s rebuild-on-open: cheap
            // (count-check) when the index is populated, essential when empty.
            await svc.rebuildIfNeeded()
            box.result = await svc.search(query: query, kinds: [kind], limit: limit)
            semaphore.signal()
        }
        semaphore.wait()
        return box.result ?? []
    }

    /// Map best-first Tantivy hits to typed summaries via the supplied catalog,
    /// preserving Tantivy's rank order. Mirrors
    /// `WikiStoreModel.resolveTantivyLeg(query:kind:limit:catalog:)` at
    /// `Sources/WikiFSCore/Store/WikiStoreModel.swift:2938` — Tantivy scores
    /// are dropped here because the store's `searchSimilar(query:limit:bm25Leg:)`
    /// treats the leg as a pre-ranked BM25 source and fuses it with the
    /// semantic cosine leg via `RankFusion.rrf`. Returns `nil` (not `[]`)
    /// when nothing resolves so the store runs WITHOUT a BM25 leg (post-#634:
    /// FTS5 is dropped, so a `nil`/empty leg means no lexical results — cosine
    /// still answers when NLEmbedding/vec are available). This matches the
    /// model's contract and is the post-#634 reality all callers route
    /// through: a missing Tantivy leg = "no BM25 leg" (no fallback path), not
    /// an error.
    private static func resolveHits<T: Identifiable & Sendable>(
        _ hits: [TantivyShadowSearchResult],
        catalog: [T]
    ) -> [T]? where T.ID == PageID {
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolved = hits.compactMap { hit -> T? in
            let id = PageID(rawValue: hit.ulid)
            return byID[id]
        }
        return resolved.isEmpty ? nil : resolved
    }
}

/// Thread-safe result box for the async→sync semaphore bridge. Mirrors
/// `RefreshResultBox` at `Sources/wikictl/main.swift` — `@unchecked Sendable`
/// is belt-and-suspenders; the semaphore guarantees the `Task`'s write
/// happens-before the read after `semaphore.wait()` returns.
private final class SearchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: [TantivyShadowSearchResult]?

    var result: [TantivyShadowSearchResult]? {
        get { lock.lock(); defer { lock.unlock() }; return _result }
        set { lock.lock(); defer { lock.unlock() }; _result = newValue }
    }
}
