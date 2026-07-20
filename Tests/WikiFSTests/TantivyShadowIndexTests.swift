import Testing
import Foundation
import WikiFSSearch

/// Phase 1 shadow-index smoke test (plans/tantivy-search-sidecar.md).
///
/// Exercises the `TantivyIndexer` + `TantivySearchService` end-to-end with an
/// in-memory `TantivyContentSource` (no SQLite, no event bus) so it runs in
/// the fast CI tier. Validates: document upsert, kind-filtered search, delete,
/// and the initial full build from `allSnapshots()`.
///
/// This does NOT wire into the production search path — it's shadow-mode
/// validation only. Tantivy BM25 + Swift cosine (`VectorCosine`) + RRF is
/// primary.
@Suite
struct TantivyShadowIndexTests {

    // MARK: - In-memory content source

    /// A minimal `TantivyContentSource` backed by an actor's dictionary — lets
    /// the test drive upsert/delete/rebuild without a real `WikiStore`. Using
    /// an actor (not `NSLock`) keeps it Swift-6-clean from async contexts.
    private actor InMemoryContentSource: TantivyContentSource {
        private var docs: [String: TantivyContentSnapshot] = [:]

        func upsert(_ snapshot: TantivyContentSnapshot) {
            let key = "\(snapshot.kind.rawValue):\(snapshot.ulid)"
            docs[key] = snapshot
        }

        func remove(ulid: String, kind: TantivyDocumentKind) {
            docs.removeValue(forKey: "\(kind.rawValue):\(ulid)")
        }

        // MARK: TantivyContentSource

        func snapshot(ulid: String, kind: TantivyDocumentKind) async throws -> TantivyContentSnapshot? {
            docs["\(kind.rawValue):\(ulid)"]
        }

        func allSnapshots() async throws -> [TantivyContentSnapshot] {
            Array(docs.values)
        }
    }

    // MARK: - Helpers

    /// Fresh temp index directory per test run (UUID) so nothing leaks between
    /// runs. Removed in `defer`.
    private func makeTempDir() -> (URL, FileManager) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tantivy-shadow-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        return (url, fm)
    }

    private func makeSnapshot(
        ulid: String,
        kind: TantivyDocumentKind,
        title: String,
        body: String
    ) -> TantivyContentSnapshot {
        TantivyContentSnapshot(
            ulid: ulid,
            kind: kind,
            title: title,
            body: body,
            updatedAt: Date(),
            versionSum: 1
        )
    }

    // MARK: - Tests

    @Test func upsertAndSearchRoundTrip() async throws {
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try TantivySearchService(
            wikiID: "test-wiki",
            containerDirectory: indexDir,
            contentSource: source
        )

        // Index three documents: two pages, one source.
        let page1 = makeSnapshot(ulid: "01PAGE0001", kind: .page, title: "Rust Ownership", body: "Borrowing and lifetimes in the Rust language.")
        let page2 = makeSnapshot(ulid: "01PAGE0002", kind: .page, title: "Swift Concurrency", body: "Actors and structured concurrency.")
        let source1 = makeSnapshot(ulid: "01SRC00001", kind: .source, title: "Tantivy Docs", body: "Full text search engine written in Rust.")
        await source.upsert(page1)
        await source.upsert(page2)
        await source.upsert(source1)

        await service.indexer.upsert(ulid: page1.ulid, kind: .page)
        await service.indexer.upsert(ulid: page2.ulid, kind: .page)
        await service.indexer.upsert(ulid: source1.ulid, kind: .source)

        let count = await service.indexer.count()
        #expect(count == 3, "three documents should be indexed")

        // Search for "rust" — should match the Rust page AND the Tantivy source
        // (body contains "Rust"). Both are lexical BM25 hits.
        let rustResults = await service.search(query: "rust", limit: 10)
        #expect(rustResults.count >= 2, "search for 'rust' should match the Rust page and the Tantivy source")
        #expect(rustResults.contains { $0.kind == .page && $0.title == "Rust Ownership" })
        #expect(rustResults.contains { $0.kind == .source && $0.title == "Tantivy Docs" })

        // Kind-filtered search: only pages.
        let pageOnly = await service.search(query: "rust", kinds: [.page], limit: 10)
        #expect(pageOnly.allSatisfy { $0.kind == .page }, "kind filter should exclude non-page results")
        #expect(pageOnly.contains { $0.title == "Rust Ownership" })
        #expect(!pageOnly.contains { $0.title == "Tantivy Docs" }, "source should be excluded by the page filter")

        // Fuzzy search: "concurency" (typo) should still match "Concurrency".
        let fuzzyResults = await service.search(query: "concurency", limit: 10)
        #expect(fuzzyResults.contains { $0.title == "Swift Concurrency" }, "fuzzy match should find 'Swift Concurrency' despite the typo")
    }

    @Test func deleteRemovesFromIndex() async throws {
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try TantivySearchService(
            wikiID: "test-wiki",
            containerDirectory: indexDir,
            contentSource: source
        )

        let page = makeSnapshot(ulid: "01PAGE0099", kind: .page, title: "Delete Me", body: "This page will be removed from the index.")
        await source.upsert(page)
        await service.indexer.upsert(ulid: page.ulid, kind: .page)
        #expect(await service.indexer.count() == 1)

        // Delete from the index (simulates a `.deleted` event).
        await service.indexer.delete(ulid: page.ulid, kind: .page)
        #expect(await service.indexer.count() == 0, "deleted document should be gone from the index")

        let results = await service.search(query: "delete", limit: 10)
        #expect(results.isEmpty, "no results should be returned after deletion")
    }

    @Test func rebuildFromContentSource() async throws {
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        // Pre-populate the source (simulating existing SQLite content).
        await source.upsert(makeSnapshot(ulid: "01PAGE0101", kind: .page, title: "Existing Page", body: "Already in the store before the index existed."))
        await source.upsert(makeSnapshot(ulid: "01CHAT0001", kind: .chat, title: "Existing Chat", body: "A conversation about search engines."))

        let service = try TantivySearchService(
            wikiID: "test-wiki",
            containerDirectory: indexDir,
            contentSource: source
        )

        // rebuildIfNeeded() should detect the empty index and build it.
        await service.rebuildIfNeeded()
        let count = await service.indexer.count()
        #expect(count == 2, "rebuild should index both pre-existing snapshots")

        // The chat should be searchable.
        let chatResults = await service.search(query: "search engines", kinds: [.chat], limit: 10)
        #expect(chatResults.count == 1)
        #expect(chatResults.first?.title == "Existing Chat")

        // The page should be searchable.
        let pageResults = await service.search(query: "store", kinds: [.page], limit: 10)
        #expect(pageResults.count == 1)
        #expect(pageResults.first?.title == "Existing Page")
    }

    @Test func upsertOfDeletedSourceMirrorsDelete() async throws {
        let (indexDir, fm) = makeTempDir()
        defer { try? fm.removeItem(at: indexDir) }

        let source = InMemoryContentSource()
        let service = try TantivySearchService(
            wikiID: "test-wiki",
            containerDirectory: indexDir,
            contentSource: source
        )

        // Index a page, then remove it from the source (simulating a race
        // where the resource was deleted between the event emit and the
        // read). The upsert should mirror the delete (snapshot returns nil).
        let page = makeSnapshot(ulid: "01PAGE0200", kind: .page, title: "Transient", body: "This will disappear.")
        await source.upsert(page)
        await service.indexer.upsert(ulid: page.ulid, kind: .page)
        #expect(await service.indexer.count() == 1)

        await source.remove(ulid: page.ulid, kind: .page)
        await service.indexer.upsert(ulid: page.ulid, kind: .page)
        #expect(await service.indexer.count() == 0, "upsert of a nil snapshot should delete the doc")
    }
}
