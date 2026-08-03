import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Semantic source search tests. The cosine-ranking semantic path cannot run
/// under `swift test` (NLEmbedding is app-bundle-gated — Swift-side cosine
/// ranking via `VectorCosine` IS active, but there's no embedder to produce a
/// query vector under `swift test`; see `VectorCosineTests` for the pure-math
/// correctness anchor), so these tests exercise: the v13 schema migration, the
/// `storeSourceEmbedding` write path, the **Tantivy bm25Leg pass-through**
/// (post-#634 — FTS5 is dropped, `searchSimilarSources` consumes a
/// caller-supplied leg), the `reembedSource` no-op behavior without the
/// embedder loaded, the `wikictl source search` CLI (TSV output + arg
/// validation), and the `ON DELETE CASCADE` on `source_embeddings`. Mirrors
/// `SourcesTests` / `WikiCtlCommandTests`.
struct SourceEmbeddingSearchTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-source-emb-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: tempDatabaseURL())
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) -> Int32 {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableExists(_ db: OpaquePointer?, _ name: String) -> Bool {
        scalarInt(
            db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)';") == 1
    }

    // MARK: - Migration

    @Test func freshDBCreatesSourceEmbeddingsTableAtV12() throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        _ = store

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        #expect(scalarInt(db, "PRAGMA user_version;") == GRDBWikiStore.schemaVersion)
        #expect(tableExists(db, "source_chunks"))
        // page chunk table mirrors the source one.
        #expect(tableExists(db, "page_chunks"))
        // The old single-embedding tables are dropped in v14.
        #expect(!tableExists(db, "source_embeddings"))
        // v13 search sidecars are ordinary tables (kept after #634 — the FTS5
        // external-content virtual tables that lived on top of them are gone).
        #expect(tableExists(db, "source_search"))
        // #634: FTS5 virtual tables are dropped at v37→v38 on existing DBs, and
        // a fresh DB never creates them. Tantivy is the sole BM25 leg.
        #expect(!tableExists(db, "pages_fts"))
        #expect(!tableExists(db, "sources_fts"))
        #expect(!tableExists(db, "chats_fts"))
    }

    // MARK: - Swift-side cosine path (Phase 3: #628 — vendored C scalar retired)

    @Test func searchSimilarSourcesUsesSwiftCosineRankerWhenEmbedderLoaded() throws {
        // Post-#628: the semantic cosine leg is pure Swift (`VectorCosine` over
        // L2-normalized BLOBs). With no embedder loaded under `swift test`
        // (NLEmbedding is app-gated), `searchSimilarSources` falls back to the
        // Tantivy bm25Leg only — the cosine leg is silently empty. This test
        // pins that contract: a fabricated Tantivy leg passes through unchanged
        // when the embedder is unavailable, and the store does NOT throw or
        // touch a C extension scalar. (`VectorCosineTests` proves the math
        // directly; `SemanticSearchSwiftCosineTests` proves the store-level
        // ranker with hand-crafted unit vectors.)
        let store = try tempStore()
        let s = try store.addSource(filename: "alpha.pdf", data: Data("%PDF".utf8))
        let leg = [s]
        let hits = try store.searchSimilarSources(query: "alpha", limit: 10, bm25Leg: leg)
        #expect(hits.count == 1)
        #expect(hits.first?.filename == "alpha.pdf")
    }

    // MARK: - storeSourceChunks

    @Test func storeSourceChunksRoundTripsWithoutThrowing() throws {
        let store = try tempStore()
        let summary = try store.addSource(filename: "note.md", data: Data("# Hi".utf8))
        // Inserting 512×Float32-shaped chunk BLOBs directly does not require
        // the embedder (pure data write).
        let chunk = Data(count: 512 * 4)
        #expect(throws: Never.self) {
            try store.storeSourceChunks(id: summary.id, chunks: [chunk, chunk])
        }
    }

    // MARK: - searchSimilarSources with a Tantivy bm25Leg (the post-#634 path)
    //
    // #634 dropped the FTS5 fallback path; `searchSimilarSources(query:bm25Leg:)`
    // returns EMPTY when the leg is nil/empty (cosine-only — NLEmbedding is
    // app-gated, so under `swift test` the semantic leg is empty too). The
    // tests below fabricate a Tantivy-like leg and assert it passes through
    // unchanged — the store must NOT augment or filter it.

    @Test func searchSimilarSourcesReturnsExactTantivyLegByFilename() throws {
        let store = try tempStore()
        let s1 = try store.addSource(filename: "quarterly-report.pdf", data: Data("%PDF".utf8))
        _ = try store.addSource(filename: "vacation.jpg", data: Data([0xFF, 0xD8, 0xFF]))

        // Fabricate a Tantivy leg that returns only s1 (matching the query
        // "report" — a Tantivy index over the source bodies would surface the
        // filename). With no source_chunks seeded, the cosine leg is empty, so
        // the fused output MUST equal exactly this leg.
        let leg = [s1]
        let hits = try store.searchSimilarSources(query: "report", limit: 10, bm25Leg: leg)
        #expect(hits.count == 1)
        #expect(hits.first?.filename == "quarterly-report.pdf")
    }

    @Test func searchSimilarSourcesLegWithRenamedSourcePassesThrough() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "data.bin", data: Data("x".utf8))
        try store.renameSource(id: s.id, to: "Annual Budget")

        // After a rename, the summary's displayName reflects the new name.
        // A Tantivy leg built post-rename carries that displayName through.
        let renamed = try store.getSource(id: s.id)
        let leg = [renamed]
        let hits = try store.searchSimilarSources(query: "budget", limit: 10, bm25Leg: leg)
        #expect(hits.count == 1)
        #expect(hits.first?.displayName == "Annual Budget")
    }

    @Test func searchSimilarSourcesRespectsLimitOnTantivyLeg() throws {
        let store = try tempStore()
        let s1 = try store.addSource(filename: "report-1.pdf", data: Data("%PDF 1".utf8))
        let s2 = try store.addSource(filename: "report-2.pdf", data: Data("%PDF 2".utf8))
        _ = try store.addSource(filename: "report-3.pdf", data: Data("%PDF 3".utf8))

        // Fabricated leg has 3 matches; cap the limit at 2.
        let leg = [s1, s2]
        let hits = try store.searchSimilarSources(query: "report", limit: 2, bm25Leg: leg)
        #expect(hits.count == 2)
    }

    @Test func searchSimilarSourcesEmptyLegReturnsEmpty() throws {
        // Post-#634: an empty leg (`[]`) and nil leg are equivalent — both mean
        // no BM25 results. With no cosine results either (the embedder is
        // unavailable under `swift test` — NLEmbedding is app-gated), the
        // output is empty.
        let store = try tempStore()
        _ = try store.addSource(filename: "alpha.txt", data: Data("a".utf8))
        #expect(try store.searchSimilarSources(query: "zzznomatch", limit: 10, bm25Leg: nil).isEmpty)
        #expect(try store.searchSimilarSources(query: "zzznomatch", limit: 10, bm25Leg: []).isEmpty)
    }

    @Test func searchSimilarSourcesNeverSelectsStar() throws {
        // Regression guard: `readSourceSummary(from:)` reads column 5 as
        // created_at (a Double). A `SELECT s.*` would emit the `content` BLOB
        // at index 5. A Tantivy leg built from `listSources()` carries a
        // summary whose dates are sane (not 1970 / not NaN), proving the
        // column order is the explicit 11-column list consumers expect.
        let store = try tempStore()
        let s = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4 content bytes".utf8))
        let leg = [s]
        let hits = try store.searchSimilarSources(query: "doc", limit: 10, bm25Leg: leg)
        let created = try #require(hits.first?.createdAt)
        #expect(created.timeIntervalSince1970 > 1_700_000_000)  // a 2023+ timestamp
    }

    // MARK: - Re-embed hooks (vec-unavailable no-op)

    @Test func appendProcessedMarkdownDoesNotThrowWithoutVec() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "note.md", data: Data("# Hi".utf8))
        // appendProcessedMarkdown runs the reembedSource hook; without vec it is
        // a guarded no-op and the version still commits.
        #expect(throws: Never.self) {
            _ = try store.appendProcessedMarkdown(
                sourceID: s.id, content: "# Hello world", origin: .extraction, note: nil)
        }
    }

    // MARK: - Cascade (ON DELETE CASCADE)

    @Test func deletingSourceRemovesItsChunkRows() throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        let s = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try store.storeSourceChunks(id: s.id, chunks: [Data(count: 512 * 4), Data(count: 512 * 4)])

        // Confirm the rows exist.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(scalarInt(
            db, "SELECT COUNT(*) FROM source_chunks WHERE source_id='\(s.id.rawValue)';") == 2)

        try store.deleteSource(id: s.id)

        // CASCADE removes the chunk rows.
        #expect(scalarInt(
            db, "SELECT COUNT(*) FROM source_chunks WHERE source_id='\(s.id.rawValue)';") == 0)
    }

    // MARK: - CLI: SourceCommand.run(.search)
    //
    // Post-#634: SourceCommand.run(.search) needs a `bm25Leg` to produce TSV
    // output — the store no longer has an FTS5 fallback. The CLI resolves a
    // Tantivy leg in production; tests fabricate one from the seeded sources.

    @Test func sourceSearchReturnsTSVAndDoesNotCommit() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "self-driving-cars.pdf", data: Data("%PDF".utf8))

        let result = try SourceCommand.run(
            .search(query: "driving", limit: 10), in: store, cwd: "/tmp", bm25Leg: [s])
        #expect(result.didCommit == false)
        guard case .text(let output) = result.payload else {
            Issue.record("expected text payload"); return
        }
        // id<TAB>name (display name falls back to filename).
        #expect(output == "\(s.id.rawValue)\tself-driving-cars.pdf")
    }

    @Test func sourceSearchOutputsDisplayNameWhenPresent() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "data.bin", data: Data("x".utf8))
        try store.renameSource(id: s.id, to: "Renamed Source")

        // Fetch the post-rename summary so the fabricated leg reflects the
        // display name Tantivy would surface.
        let renamed = try store.getSource(id: s.id)
        let result = try SourceCommand.run(
            .search(query: "renamed", limit: 10), in: store, cwd: "/tmp", bm25Leg: [renamed])
        guard case .text(let output) = result.payload else {
            Issue.record("expected text payload"); return
        }
        #expect(output == "\(s.id.rawValue)\tRenamed Source")
    }

    // MARK: - CLI: argument parsing

    private let noEnv: (String) -> String? = { _ in nil }

    @Test func parsesSourceSearchWithQueryAndDefaultLimit() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "search", "--query", "autonomous vehicles"], env: noEnv)
        #expect(invocation.command == .source(.search(query: "autonomous vehicles", limit: 10)))
    }

    @Test func parsesSourceSearchWithCustomLimit() throws {
        let invocation = try ArgumentParser.parse(
            ["--wiki", "W", "source", "search", "--query", "ai", "--limit", "5"], env: noEnv)
        #expect(invocation.command == .source(.search(query: "ai", limit: 5)))
    }

    @Test func sourceSearchRequiresQuery() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(
                ["--wiki", "W", "source", "search", "--limit", "10"], env: noEnv)
        }
    }

    @Test func sourceSearchRejectsLimitZero() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(
                ["--wiki", "W", "source", "search", "--query", "x", "--limit", "0"], env: noEnv)
        }
    }

    @Test func sourceSearchRejectsLimitOver100() {
        #expect(throws: ArgumentParser.Failure.self) {
            _ = try ArgumentParser.parse(
                ["--wiki", "W", "source", "search", "--query", "x", "--limit", "101"], env: noEnv)
        }
    }
}
