import Foundation
import Testing
@testable import WikiFSCore

/// Coverage for `pagesCitingSources(sourceIDs:limit:)` — the bounded,
/// read-only inverse provenance lookup that resolves the queue Overview's
/// "Outputs" section from recorded citation evidence (never from job
/// outcomes). Fixtures write citations through the production writer seam
/// (`appendPageVersion` provenance inputs), so the read is verified against
/// exactly the edges the ingestion pipeline records.
struct PagesCitingSourcesTests {
    /// Cite `sourceIDs` from a new version of `pageID` (distinct body per
    /// call so the append never amend-coalesces into the previous version).
    @discardableResult
    private func cite(
        _ store: GRDBWikiStore,
        pageID: PageID,
        title: String,
        body: String,
        sourceIDs: [SourceID]
    ) throws -> PageVersionID {
        let head = try store.pageHeadVersionID(pageID: pageID)
        return try store.appendPageVersion(
            pageID: pageID, title: title, body: body,
            expectedHeadVersionID: head, lastEditedBy: nil,
            provenance: PageVersionSourceInput.agentIngest(sourceIDs: sourceIDs))
    }

    @Test func returnsEmptyForUnknownSource() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(try store.pagesCitingSources(
            sourceIDs: [SourceID(rawValue: "missing")], limit: 10).isEmpty)
    }

    @Test func returnsEmptyForUncitedSource() throws {
        let store = try TestStoreFactory.inMemory()
        let uncited = try store.addSource(filename: "uncited.txt", data: Data("x".utf8))
        let page = try store.createPage(title: "Page")
        let other = try store.addSource(filename: "other.txt", data: Data("y".utf8))
        try cite(store, pageID: page.id, title: "Page", body: "one", sourceIDs: [other.id])
        // The page cites `other`, so `uncited` has no citation evidence.
        #expect(try store.pagesCitingSources(sourceIDs: [uncited.id], limit: 10).isEmpty)
    }

    @Test func returnsEmptyForEmptyOrNonPositiveLimit() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "a.txt", data: Data("a".utf8))
        #expect(try store.pagesCitingSources(sourceIDs: [source.id], limit: 0).isEmpty)
        #expect(try store.pagesCitingSources(sourceIDs: [source.id], limit: -3).isEmpty)
        #expect(try store.pagesCitingSources(sourceIDs: [], limit: 10).isEmpty)
    }

    @Test func returnsDistinctPagesInCaseInsensitiveTitleOrder() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "a.txt", data: Data("a".utf8))
        let supporting = try store.addSource(filename: "b.txt", data: Data("b".utf8))
        let zulu = try store.createPage(title: "Zulu")
        let alpha = try store.createPage(title: "alpha")
        try cite(store, pageID: zulu.id, title: "Zulu", body: "one", sourceIDs: [source.id])
        try cite(store, pageID: alpha.id, title: "alpha", body: "two", sourceIDs: [source.id, supporting.id])

        // One input: both citing pages, title order case-insensitive
        // ("alpha" before "Zulu"), titles resolved from the live pages rows.
        // Ordering per protocol: live (non-nil-title) pages first, then
        // page id; `nil`-title rows sort LAST (the `(p.title IS NULL)` sort
        // key). That NULL placement is not exercisable through public APIs —
        // an orphan citation edge cannot be produced (page deletes cascade
        // their edges away) — so the hosted suite's nil-title fixture stays
        // synthetic.
        let one = try store.pagesCitingSources(sourceIDs: [source.id], limit: 10)
        #expect(one.map(\.pageID) == [alpha.id, zulu.id])
        #expect(one.map(\.title) == ["alpha", "Zulu"])

        // Both inputs: the multi-input page appears exactly once — the
        // result is DISTINCT pages, not citation edges.
        let both = try store.pagesCitingSources(
            sourceIDs: [source.id, supporting.id], limit: 10)
        #expect(both.map(\.pageID) == [alpha.id, zulu.id])
    }

    @Test func multipleVersionsOfSamePageCollapseToOneRow() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "a.txt", data: Data("a".utf8))
        let page = try store.createPage(title: "Page")
        try cite(store, pageID: page.id, title: "Page", body: "one", sourceIDs: [source.id])
        try cite(store, pageID: page.id, title: "Page", body: "two", sourceIDs: [source.id])
        let rows = try store.pagesCitingSources(sourceIDs: [source.id], limit: 10)
        #expect(rows.map(\.pageID) == [page.id])
    }

    @Test func limitCapsResultInTitleOrder() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "a.txt", data: Data("a".utf8))
        let pages = try [
            store.createPage(title: "C-page"),
            store.createPage(title: "A-page"),
            store.createPage(title: "B-page"),
        ]
        for page in pages {
            try cite(store, pageID: page.id, title: page.title, body: "body", sourceIDs: [source.id])
        }
        let rows = try store.pagesCitingSources(sourceIDs: [source.id], limit: 2)
        #expect(rows.map(\.title) == ["A-page", "B-page"])
    }

    @Test func deletedPageDropsOutOfOutputs() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "a.txt", data: Data("a".utf8))
        let page = try store.createPage(title: "Ephemeral")
        try cite(store, pageID: page.id, title: "Ephemeral", body: "one", sourceIDs: [source.id])
        #expect(try store.pagesCitingSources(sourceIDs: [source.id], limit: 10).count == 1)
        // Deleting the page cascades its versions and citation edges away:
        // the output is gone from the evidence, not renamed or faked.
        try store.deletePage(id: page.id)
        #expect(try store.pagesCitingSources(sourceIDs: [source.id], limit: 10).isEmpty)
    }

    @Test func duplicateSourceArgumentsDoNotDistortResults() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "a.txt", data: Data("a".utf8))
        let page = try store.createPage(title: "Page")
        try cite(store, pageID: page.id, title: "Page", body: "one", sourceIDs: [source.id])
        let rows = try store.pagesCitingSources(
            sourceIDs: [source.id, source.id], limit: 10)
        #expect(rows.map(\.pageID) == [page.id])
    }
}
