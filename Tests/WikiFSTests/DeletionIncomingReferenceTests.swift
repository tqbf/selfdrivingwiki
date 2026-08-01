#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore

/// Store + model tests for the issue #219 delete-with-incoming-references flow:
/// `pageLinkingPages`, `deletionImpact`, and `delete(_:unlinkIncomingLinks:)`
/// for both pages and sources.
@MainActor
struct DeletionIncomingReferenceTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-delete-refs-\(UUID().uuidString).sqlite")
    }

    private func makeStore() throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: tempURL())
    }

    // MARK: - pageLinkingPages (store)

    @Test func pageLinkingPagesReportsIncomingEdges() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")

        // A links to B.
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")

        #expect(try store.pageLinkingPages(to: b.id) == [a.id])
        #expect(try store.pageLinkingPages(to: a.id).isEmpty)
    }

    // MARK: - deletionImpact

    @Test func deletionImpactForPageReportsLinksAndBookmarks() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))

        let model = WikiStoreModel(store: store)
        model.reloadBookmarkNodes()

        let impact = model.deletionImpact(forPage: b.id)
        #expect(impact.linkingPageIDs == [a.id])
        #expect(impact.bookmarkLabels.count == 1)
        #expect(impact.hasReferences)
    }

    @Test func deletionImpactForPageWithNoReferencesIsEmpty() throws {
        let store = try makeStore()
        let b = try store.createPage(title: "B")
        let model = WikiStoreModel(store: store)

        let impact = model.deletionImpact(forPage: b.id)
        #expect(!impact.hasReferences)
    }

    @Test func deletionImpactForSourceReportsCitations() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "cite [[source:paper]]", author: "user")

        let model = WikiStoreModel(store: store)
        let impact = model.deletionImpact(forSource: src.id)
        #expect(impact.linkingPageIDs == [a.id])
        #expect(impact.hasReferences)
    }

    // MARK: - delete(_:unlinkIncomingLinks:)

    @Test func deletePageWithUnlinkConvertsIncomingLinksToPlainText() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]] end", author: "user")

        let model = WikiStoreModel(store: store)
        model.delete(b.id, unlinkIncomingLinks: true)

        // A's link to B is now plain text.
        #expect(try store.getPage(id: a.id).bodyMarkdown == "see B end")
        // B is gone.
        let remainingIDs = Set(try store.listPages(sortBy: .lastUpdated).map(\.id))
        #expect(!remainingIDs.contains(b.id))
        // The page_links edge A→B no longer exists.
        #expect(try store.listAllLinks().isEmpty)
    }

    @Test func deletePageWithoutUnlinkLeavesGhostLink() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")

        let model = WikiStoreModel(store: store)
        model.delete(b.id, unlinkIncomingLinks: false)

        // The body still carries the [[…]] syntax (now a ghost link).
        let body = try store.getPage(id: a.id).bodyMarkdown
        #expect(body.contains("[[") && body.contains("]]"))
        // But the link row is cleaned up by deletePage's FK sweep.
        #expect(try store.listAllLinks().isEmpty)
    }

    @Test func deletePageRemovesReferencingBookmarks() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "see [[B]]", author: "user")
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(b.id))

        let model = WikiStoreModel(store: store)
        model.reloadBookmarkNodes()
        model.delete(b.id, unlinkIncomingLinks: false)

        // The bookmark to B is gone.
        #expect(try store.listBookmarkNodes().isEmpty)
    }

    // MARK: - deleteSource(_:unlinkIncomingLinks:)

    @Test func deleteSourceWithUnlinkConvertsCitationsToPlainText() throws {
        let store = try makeStore()
        let a = try store.createPage(title: "A")
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        try PageUpsert.upsert(in: store, id: a.id, title: "A", body: "cite [[source:paper]]", author: "user")

        let model = WikiStoreModel(store: store)
        model.deleteSource(src.id, unlinkIncomingLinks: true)

        // The citation is now plain text.
        let body = try store.getPage(id: a.id).bodyMarkdown
        #expect(!body.contains("[["))
        #expect(body.contains("paper"))
    }

    @Test func deleteSourceRemovesReferencingBookmarks() throws {
        let store = try makeStore()
        let src = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .source(src.id))

        let model = WikiStoreModel(store: store)
        model.reloadBookmarkNodes()
        model.deleteSource(src.id, unlinkIncomingLinks: false)

        #expect(try store.listBookmarkNodes().isEmpty)
    }

    // MARK: - provenance restriction (sources the agent has used)

    @Test func deletionImpactForSourceReportsProvenanceBlockers() throws {
        let store = try makeStore()
        let page = try store.createPage(title: "Claim")
        let src = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(
            id: page.id, title: page.title, body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: src.id, role: .primary)])

        let model = WikiStoreModel(store: store)
        let impact = model.deletionImpact(forSource: src.id)
        #expect(impact.isProvenanceBlocked)
        #expect(impact.provenanceBlockers.count == 1)
    }

    @Test func provenanceBlockedSourceIsNotDeletedAndCitationsSurvive() throws {
        let store = try makeStore()
        let page = try store.createPage(title: "Claim")
        let src = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(
            id: page.id, title: page.title, body: "cite [[source:evidence]]", lastEditedBy: "user",
            provenance: [.init(sourceID: src.id, role: .primary)])

        let model = WikiStoreModel(store: store)
        model.deleteSource(src.id, unlinkIncomingLinks: true)

        // The source stays (provenance-restricted) …
        #expect(try store.getSource(id: src.id).id == src.id)
        // … and its citation is NOT rewritten (we bailed before unlinking).
        #expect(try store.getPage(id: page.id).bodyMarkdown.contains("[["))
        // The restriction is surfaced as a store error.
        #expect(model.storeError != nil)
    }
}
#endif
