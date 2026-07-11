import Foundation
import SQLite3
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Semantic source search tests. The cosine-ranking semantic path cannot run
/// under `swift test` (NLEmbedding is app-bundle-gated — sqlite-vec itself is
/// now statically linked and registered; see
/// `vecScalarIsRegisteredAfterStaticLink`), so these tests exercise: the v13 schema migration,
/// the `storeSourceEmbedding` write path, the **LIKE fallback** search, the
/// `reembedSource` no-op behavior without vec, the `wikictl source search` CLI
/// (TSV output + arg validation), and the `ON DELETE CASCADE` on
/// `source_embeddings`. Mirrors `SourcesTests` / `WikiCtlCommandTests`.
struct SourceEmbeddingSearchTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-source-emb-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
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
        let store = try SQLiteWikiStore(databaseURL: url)
        _ = store

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        #expect(scalarInt(db, "PRAGMA user_version;") == 32)
        #expect(tableExists(db, "source_chunks"))
        // page chunk table mirrors the source one.
        #expect(tableExists(db, "page_chunks"))
        // The old single-embedding tables are dropped in v14.
        #expect(!tableExists(db, "source_embeddings"))
        // v13: FTS5 full-text search tables.
        #expect(tableExists(db, "pages_fts"))
        #expect(tableExists(db, "sources_fts"))
        #expect(tableExists(db, "source_search"))
    }

    // MARK: - vec registration (Phase 2: statically-linked sqlite-vec)

    @Test func vecScalarIsRegisteredAfterStaticLink() throws {
        // sqlite-vec is compiled in (-DSQLITE_CORE) and registered on every
        // connection now. The cosine semantic path still can't RANK under swift
        // test (NLEmbedding is app-gated), but this proves the scalar functions
        // exist — the core Phase 2 guarantee.
        let store = try tempStore()
        #expect(store.vecRegisteredForTesting, "sqlite-vec should be registered on the connection")
    }

    // MARK: - storeSourceChunks

    @Test func storeSourceChunksRoundTripsWithoutThrowing() throws {
        let store = try tempStore()
        let summary = try store.addSource(filename: "note.md", data: Data("# Hi".utf8))
        // Inserting 512×Float32-shaped chunk BLOBs directly does not require vec.
        let chunk = Data(count: 512 * 4)
        #expect(throws: Never.self) {
            try store.storeSourceChunks(id: summary.id, chunks: [chunk, chunk])
        }
    }

    // MARK: - searchSimilarSources LIKE fallback

    @Test func searchSimilarSourcesLIKEFallbackFindsByFilename() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "quarterly-report.pdf", data: Data("%PDF".utf8))
        _ = try store.addSource(filename: "vacation.jpg", data: Data([0xFF, 0xD8, 0xFF]))

        let hits = try store.searchSimilarSources(query: "report", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.filename == "quarterly-report.pdf")
    }

    @Test func searchSimilarSourcesLIKEFallbackMatchesDisplayName() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "data.bin", data: Data("x".utf8))
        try store.renameSource(id: s.id, to: "Annual Budget")

        let hits = try store.searchSimilarSources(query: "budget", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.displayName == "Annual Budget")
    }

    @Test func searchSimilarSourcesLIKEFallbackRespectsLimit() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "report-1.pdf", data: Data("%PDF 1".utf8))
        _ = try store.addSource(filename: "report-2.pdf", data: Data("%PDF 2".utf8))
        _ = try store.addSource(filename: "report-3.pdf", data: Data("%PDF 3".utf8))

        let hits = try store.searchSimilarSources(query: "report", limit: 2)
        #expect(hits.count == 2)
    }

    @Test func searchSimilarSourcesLIKEFallbackEmptyWhenNoMatch() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "alpha.txt", data: Data("a".utf8))
        #expect(try store.searchSimilarSources(query: "zzznomatch", limit: 10).isEmpty)
    }

    @Test func searchSimilarSourcesNeverSelectsStar() throws {
        // Regression guard: `sourceSummary(from:)` reads column 5 as created_at
        // (a Double). `SELECT s.*` would emit the `content` BLOB at index 5.
        // The LIKE fallback returns a summary whose dates are sane (not 1970 /
        // not NaN), proving the column order is the explicit 11-column list.
        let store = try tempStore()
        _ = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4 content bytes".utf8))
        let hits = try store.searchSimilarSources(query: "doc", limit: 10)
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
                sourceID: s.id, content: "# Hello world", origin: "extraction", note: nil)
        }
    }

    // MARK: - Cascade (ON DELETE CASCADE)

    @Test func deletingSourceRemovesItsChunkRows() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
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

    @Test func sourceSearchReturnsTSVAndDoesNotCommit() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "self-driving-cars.pdf", data: Data("%PDF".utf8))

        let result = try SourceCommand.run(
            .search(query: "driving", limit: 10), in: store, cwd: "/tmp")
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

        let result = try SourceCommand.run(
            .search(query: "renamed", limit: 10), in: store, cwd: "/tmp")
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
