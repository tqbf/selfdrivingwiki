import Foundation
import Testing
@testable import WikiFSCore

/// Store-level tests for the OKF v0.2 §5.1 credibility-signal reads —
/// `sourceUsageSignals` / `sourceHeadProducers` (issue #927). Pure reads
/// against in-memory fixtures; the projection wiring is covered by
/// `ProjectionTreeTests` / `ProjectionTests`.
@Suite struct SourceUsageSignalTests {

    private struct Seeded {
        let store: GRDBWikiStore
        let a: WikiPage
        let b: WikiPage
        let cited: SourceSummary      // cite edges from A and B
        let embeddedOnly: SourceSummary // embed edge from A only
        let uncited: SourceSummary
    }

    /// Page A cites `cited`; page B cites `cited` later (so B's `updated_at`
    /// is the MAX); A embeds `embeddedOnly`; `uncited` has no links.
    private func seed() throws -> Seeded {
        let store = try TestStoreFactory.inMemory()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let cited = try store.addSource(
            filename: "cited.pdf", data: Data("%PDF fake".utf8), mimeType: "application/pdf")
        let embeddedOnly = try store.addSource(
            filename: "embedded.png", data: Data("png".utf8), mimeType: "image/png")
        let uncited = try store.addSource(
            filename: "lonely.txt", data: Data("plain".utf8), mimeType: "text/plain")
        // A cites AND embeds in one body (replaceLinks rebuilds ALL of a
        // page's edges per call, so each page gets exactly one writeBody).
        try writeBody(store, page: a,
                      "[[source:\(cited.id.rawValue)|doc]] ![[source:\(embeddedOnly.id.rawValue)|img]]")
        try writeBody(store, page: b, "[[source:\(cited.id.rawValue)|doc too]]")
        return Seeded(store: store, a: a, b: b, cited: cited,
                      embeddedOnly: embeddedOnly, uncited: uncited)
    }

    /// Replace the page body and rebuild its link edges, like the app does.
    private func writeBody(_ store: GRDBWikiStore, page: WikiPage, _ body: String) throws {
        try store.updatePage(id: page.id, title: page.title, body: body)
        try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(body))
    }

    private func page(_ title: String, in store: GRDBWikiStore) throws -> WikiPage {
        try #require(try store.listAllPagesOrderedByID().first { $0.title == title })
    }

    @Test func countsDistinctCitingPagesWithLatestUpdatedAt() throws {
        let f = try seed()
        let signals = try f.store.sourceUsageSignals(
            sourceIDs: [f.cited.id, f.embeddedOnly.id, f.uncited.id])

        let cited = try #require(signals[f.cited.id])
        #expect(cited.sourceID == f.cited.id)
        #expect(cited.citeCount == 2)
        // The window's `to` bound is the newest updated_at among citing pages.
        let a = try page("A", in: f.store)
        let b = try page("B", in: f.store)
        #expect(cited.latestCitingPageUpdatedAt == max(a.updatedAt, b.updatedAt))
        // Uncited sources are absent — callers treat missing as count 0.
        #expect(signals[f.embeddedOnly.id] == nil)
        #expect(signals[f.uncited.id] == nil)
    }

    @Test func embedEdgesAreExcludedAndCoexistWithCiteEdges() throws {
        let f = try seed()
        // A additionally EMBEDS the cited source: the embed edge coexists with
        // the cite edges (distinct rows under `source_links_edge`) and must
        // not inflate the cite count.
        try writeBody(f.store, page: f.a,
                      "[[source:\(f.cited.id.rawValue)|doc]] ![[source:\(f.cited.id.rawValue)|img]]")
        let signals = try f.store.sourceUsageSignals(sourceIDs: [f.cited.id])
        #expect(signals[f.cited.id]?.citeCount == 2)
    }

    @Test func linkDeletionIsReflected() throws {
        let f = try seed()
        // B drops its citation (body rewritten without the cite link).
        try writeBody(f.store, page: f.b, "B no longer cites anything.")
        let signals = try f.store.sourceUsageSignals(sourceIDs: [f.cited.id])
        let signal = try #require(signals[f.cited.id])
        #expect(signal.citeCount == 1)
        let a = try page("A", in: f.store)
        #expect(signal.latestCitingPageUpdatedAt == a.updatedAt)
    }

    @Test func emptyAndUnknownInputsReturnEmptyOrAbsent() throws {
        let f = try seed()
        #expect(try f.store.sourceUsageSignals(sourceIDs: []) == [:])
        #expect(try f.store.sourceHeadProducers(sourceIDs: []) == [:])
        let unknown = SourceID(rawValue: "01UNKNOWN")
        #expect(try f.store.sourceUsageSignals(sourceIDs: [unknown])[unknown] == nil)
        // Duplicate ids resolve once (deduped input).
        let signals = try f.store.sourceUsageSignals(sourceIDs: [f.cited.id, f.cited.id])
        #expect(signals.count == 1)
        #expect(signals[f.cited.id]?.citeCount == 2)
    }

    @Test func headProducersReturnRecordedProducerAndNilWithoutOne() throws {
        let store = try TestStoreFactory.inMemory()
        let extracted = try store.addSource(
            filename: "paper.pdf", data: Data("%PDF fake".utf8), mimeType: "application/pdf")
        // Extraction with a technique records an activity + agent (producer).
        _ = try store.appendProcessedMarkdown(
            sourceID: extracted.id, content: "# Extracted", origin: .extraction,
            note: nil, technique: "anthropic")
        // A user-origin version records NO producer.
        let manual = try store.addSource(
            filename: "notes.txt", data: Data("plain".utf8), mimeType: "text/plain")
        _ = try store.appendProcessedMarkdown(
            sourceID: manual.id, content: "# Manual", origin: .user,
            note: nil, technique: nil)

        let producers = try store.sourceHeadProducers(sourceIDs: [extracted.id, manual.id])
        let recorded = try #require(producers[extracted.id])
        #expect(recorded.producerName?.isEmpty == false)
        let unrecorded = try #require(producers[manual.id])
        #expect(unrecorded.producerName == nil)
        #expect(unrecorded.producerVersion == nil)
    }

    @Test func signalsResolveOnReadOnlyConnections() throws {
        // The File Provider extension reads through `GRDBWikiStore(readOnlyURL:)`
        // — both aggregates must work there (plain SELECTs, no mutate()).
        let backed = try TestStoreFactory.fileBacked(prefix: "usage-signals")
        let cited = try backed.store.addSource(
            filename: "cited.pdf", data: Data("%PDF fake".utf8), mimeType: "application/pdf")
        let a = try backed.store.createPage(title: "A")
        try backed.store.updatePage(
            id: a.id, title: "A", body: "[[source:\(cited.id.rawValue)|doc]]")
        try backed.store.replaceLinks(
            from: a.id, parsedLinks: WikiLinkParser.parse("[[source:\(cited.id.rawValue)|doc]]"))
        _ = try backed.store.appendProcessedMarkdown(
            sourceID: cited.id, content: "# Extracted", origin: .extraction,
            note: nil, technique: "anthropic")

        let readOnly = try GRDBWikiStore(readOnlyURL: backed.url)
        let signals = try readOnly.sourceUsageSignals(sourceIDs: [cited.id])
        #expect(signals[cited.id]?.citeCount == 1)
        let producers = try readOnly.sourceHeadProducers(sourceIDs: [cited.id])
        #expect(producers[cited.id]?.producerName?.isEmpty == false)
    }
}
