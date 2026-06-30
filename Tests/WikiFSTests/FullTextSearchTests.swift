import Foundation
import SQLite3
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// FTS5/BM25 full-text search tests (v13). Unlike the vec semantic path, FTS5 is
/// NOT app-gated — it runs fully under `swift test`. These cover the new
/// capability the LIKE fallback lacked: matching the document **body** (not just
/// the filename/title), plus cascade and the Reindex rebuild.
struct FullTextSearchTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-fts-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - Body search (the new capability — AC.1)

    @Test func pageBodySearchFindsContentWithZeroTitleOverlap() throws {
        let store = try tempStore()
        // Title says nothing about hypnosis; the body does.
        let page = try store.createPage(title: "Lecture Notes")
        try store.updatePage(id: page.id, title: "Lecture Notes",
                             body: "Today we covered clinical hypnosis and suggestion.")
        let hits = try store.searchSimilar(query: "hypnosis", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.id == page.id)
    }

    @Test func sourceBodySearchFindsContentWithZeroFilenameOverlap() throws {
        let store = try tempStore()
        // Filename says nothing about hypnosis; the processed-markdown body does.
        let s = try store.addSource(filename: "paper-2024.pdf", data: Data("%PDF".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: s.id, content: "Hypnosis measurably alters pain perception.",
            origin: "extraction", note: nil)
        let hits = try store.searchSimilarSources(query: "hypnosis", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.id == s.id)
    }

    @Test func porterStemmingMatchesInflections() throws {
        // The porter tokenizer stems both index and query, so "running" ↔ "run".
        let store = try tempStore()
        let page = try store.createPage(title: "Training")
        try store.updatePage(id: page.id, title: "Training", body: "She is running every morning.")
        #expect(try store.searchSimilar(query: "run", limit: 10).first?.id == page.id)
    }

    // MARK: - Name-only indexing (un-extracted source findable by filename)

    @Test func unextractedSourceFindableByFilename() throws {
        let store = try tempStore()
        _ = try store.addSource(filename: "hypnosis-study.pdf", data: Data("%PDF".utf8))
        let hits = try store.searchSimilarSources(query: "hypnosis", limit: 10)
        #expect(hits.count == 1)
    }

    // MARK: - Ranking (AC: better match ranks first)

    @Test func bm25RanksMoreRelevantPageFirst() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "A")
        try store.updatePage(id: a.id, title: "A",
                             body: "thermodynamics thermodynamics thermodynamics thermodynamics")
        let b = try store.createPage(title: "B")
        try store.updatePage(id: b.id, title: "B", body: "a brief mention of thermodynamics")
        let hits = try store.searchSimilar(query: "thermodynamics", limit: 10)
        #expect(hits.count == 2)
        #expect(hits.first?.id == a.id)  // higher term frequency → better bm25
    }

    // MARK: - Cascade (AC.5)

    @Test func deletingPageRemovesItFromFTS() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Gone")
        try store.updatePage(id: page.id, title: "Gone", body: "contains qxzuniqueterm")
        #expect(try store.searchSimilar(query: "qxzuniqueterm", limit: 10).count == 1)
        try store.deletePage(id: page.id)
        #expect(try store.searchSimilar(query: "qxzuniqueterm", limit: 10).isEmpty)
    }

    // MARK: - Reindex rebuild (Reindex button backfills pre-existing content)

    @Test func rebuildFTSIndexesAllPagesAndSources() throws {
        let store = try tempStore()
        _ = try store.createPage(title: "Page One")
        _ = try store.createPage(title: "Page Two")
        let s = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: s.id, content: "indexed body text", origin: "extraction", note: nil)

        let counts = store.rebuildFTS()
        #expect(counts.pages >= 2)
        #expect(counts.sources >= 1)
        // Idempotent: a second run yields the same (non-empty) counts.
        let again = store.rebuildFTS()
        #expect(again.pages == counts.pages)
        #expect(again.sources == counts.sources)
    }

    // MARK: - Launch self-heal of an empty term index (the ranking bug)

    /// Regression test for the search-ranking bug: an external-content FTS5
    /// table reports `count(*) == pages.count` (it reads the content table), so
    /// the launch health check (`pages_fts < pages`) was ALWAYS false and the
    /// rebuild never ran. A DB whose pages predated the FTS triggers ended up
    /// with pages_fts "232/232" but ZERO indexed terms → MATCH returned nothing
    /// → the hybrid search degraded to semantic-only and ranked short queries
    /// ("scala", "java") arbitrarily. Opening the store must detect the empty
    /// term index and rebuild it.
    @Test func emptyFtsTermIndexIsHealedOnOpen() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Claim Notes")
        try store.updatePage(id: page.id, title: "Claim Notes",
                             body: "Details about the insurance claim and appeal process.")
        // Baseline: a healthy index finds the body term.
        #expect(try store.searchSimilar(query: "insurance", limit: 10).contains { $0.id == page.id })

        // Reproduce the broken state: pages exist, but the FTS term index is
        // empty (as when pages predate the FTS triggers).
        try store._breakPagesFtsIndexForTesting()
        #expect(try store.searchSimilar(query: "insurance", limit: 10).isEmpty)

        // Re-opening runs ensureSearchIndexes, which must now see zero terms and
        // rebuild → the body term is findable again.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let hits = try reopened.searchSimilar(query: "insurance", limit: 10)
        #expect(hits.contains { $0.id == page.id })
    }
}
