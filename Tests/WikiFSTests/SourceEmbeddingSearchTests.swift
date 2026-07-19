import Foundation
import SQLite3
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Semantic source search tests. The cosine-ranking semantic path cannot run
/// under `swift test` (NLEmbedding is app-bundle-gated — sqlite-vec itself is
/// now statically linked and registered; see
/// `vecScalarIsRegisteredAfterStaticLink`), so these tests exercise: the
/// schema migration, the `storeSourceEmbedding` write path, the `reembedSource`
/// no-op behavior without vec, the `wikictl source search` CLI (TSV output +
/// arg validation), and the `ON DELETE CASCADE` on `source_embeddings`.
/// Mirrors `SourcesTests` / `WikiCtlCommandTests`.
///
/// The lexical/BM25 path (FTS5 pre-v38, Tantivy as of v38/#634) is not
/// exercised here — `TantivyBM25LegCutoverTests` + `CLITantivyLegResolverTests`
/// cover the BM25 leg. A `bm25Leg: nil` to `searchSimilarSources` after #634
/// means "no BM25 leg" — empty result when vec is unavailable.
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
        // v38 (#634): FTS5/BM25 tables + sidecars are dropped — Tantivy is
        // the sole BM25 search path. A fresh DB must never create them.
        #expect(!tableExists(db, "pages_fts"))
        #expect(!tableExists(db, "sources_fts"))
        #expect(!tableExists(db, "chats_fts"))
        #expect(!tableExists(db, "source_search"))
        #expect(!tableExists(db, "chat_search"))
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

    // MARK: - searchSimilarSources: no BM25 leg under `swift test`
    //
    // Post-#634 (v38), a `bm25Leg: nil` means "no BM25 leg" — Tantivy is the
    // sole BM25 path and there's no FTS5 fallback. Under `swift test`
    // (NLEmbedding-gated vec unavailable), the store returns no source hits
    // when no leg is supplied. `TantivyBM25LegCutoverTests` covers the
    // leg-supplied path; `CLITantivyLegResolverTests` covers the CLI's
    // Tantivy leg resolution.

    @Test func searchSimilarSourcesEmptyWithoutBm25LegUnderSwiftTest() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "quarterly-report.pdf", data: Data("%PDF".utf8))
        _ = try store.addSource(filename: "vacation.jpg", data: Data([0xFF, 0xD8, 0xFF]))

        // No Tantivy leg, vec unavailable → no BM25 leg, no cosine leg → empty.
        let hits = try store.searchSimilarSources(query: "report", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    @Test func searchSimilarSourcesUsesSuppliedBm25Leg() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "quarterly-report.pdf", data: Data("%PDF".utf8))
        // Caller-supplied BM25 leg (the contract the model +
        // CLITantivyLegResolver fulfill in production via Tantivy). With no
        // chunk embeddings seeded, the semantic leg is empty → fused == leg.
        let leg = [SourceSummary(
            id: s.id, filename: s.filename, ext: s.ext, mimeType: s.mimeType,
            byteSize: s.byteSize, createdAt: s.createdAt, updatedAt: s.updatedAt,
            version: s.version, zoteroItemKey: nil, zoteroItemTitle: nil,
            displayName: s.displayName, role: s.role)]
        let hits = try store.searchSimilarSources(query: "report", limit: 10, bm25Leg: leg)
        #expect(hits.count == 1)
        #expect(hits.first?.id == s.id)
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
    // Post-#634 (v38): Tantivy is the sole BM25 path. `SourceCommand.run`'s
    // default `bm25Leg: nil` means "no BM25 leg" — under `swift test` (vec
    // unavailable), the search returns nothing unless the caller supplies a
    // leg. In production `wikictl` resolves one via `CLITantivyLegResolver`
    // (covered by `CLITantivyLegResolverTests`); these tests supply a
    // synthetic leg to verify the TSV formatting + commit semantics.

    @Test func sourceSearchReturnsTSVAndDoesNotCommit() throws {
        let store = try tempStore()
        let s = try store.addSource(filename: "self-driving-cars.pdf", data: Data("%PDF".utf8))

        let leg = [SourceSummary(
            id: s.id, filename: s.filename, ext: s.ext, mimeType: s.mimeType,
            byteSize: s.byteSize, createdAt: s.createdAt, updatedAt: s.updatedAt,
            version: s.version, zoteroItemKey: nil, zoteroItemTitle: nil,
            displayName: s.displayName, role: s.role)]
        let result = try SourceCommand.run(
            .search(query: "driving", limit: 10), in: store, cwd: "/tmp", bm25Leg: leg)
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

        // The rename updates `display_name` on `sources`. The synthetic leg
        // must reflect the post-rename summary (mirrors what
        // `CLITantivyLegResolver` reads from `store.listSources()` in
        // production).
        let renamed = try store.listSources().first { $0.id == s.id } ?? s
        let leg = [renamed]
        let result = try SourceCommand.run(
            .search(query: "renamed", limit: 10), in: store, cwd: "/tmp", bm25Leg: leg)
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
