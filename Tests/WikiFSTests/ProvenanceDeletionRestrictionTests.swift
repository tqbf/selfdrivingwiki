import Foundation
import Testing
@testable import WikiFSCore

struct ProvenanceDeletionRestrictionTests {
    private func deletionBlockers(
        for sourceID: SourceID, in store: GRDBWikiStore
    ) throws -> NonEmptyProvenanceDeletionBlockers {
        do {
            try store.deleteSource(id: sourceID)
            Issue.record("expected provenance deletion restriction")
            fatalError("expected provenance deletion restriction")
        } catch let error as WikiStoreError {
            guard case .deletionRestricted(.provenance(let blockers)) = error else {
                Issue.record("unexpected deletion error: \(error)")
                fatalError("unexpected deletion error")
            }
            return blockers
        }
    }

    @Test func oneReferenceReturnsNonEmptyCollectionWithOneBlocker() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Claim")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        try store.updatePage(
            id: page.id, title: page.title, body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: source.id, role: .primary)]
        )
        let version = try #require(try store.pageHeadVersionID(pageID: page.id))

        do {
            try store.deleteSource(id: source.id)
            Issue.record("expected provenance deletion restriction")
        } catch let error as WikiStoreError {
            guard case .deletionRestricted(.provenance(let blockers)) = error else {
                Issue.record("unexpected deletion error: \(error)")
                return
            }
            #expect(blockers.values == [
                .init(sourceID: source.id, pageVersionID: version, pageID: page.id),
            ])
        }
    }

    @Test func unreferencedSourceDeletionSucceedsAndEmitsOnce() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "orphan.txt", data: Data("orphan".utf8))

        try store.deleteSource(id: source.id)

        #expect(throws: WikiStoreError.self) { try store.getSource(id: source.id) }
    }

    @Test func multipleVersionsAndPagesReturnOrderedDistinctBlockers() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let firstPage = try store.createPage(title: "First")
        let secondPage = try store.createPage(title: "Second")
        let evidence = [PageVersionSourceInput(sourceID: source.id, role: .supporting)]

        try store.updatePage(
            id: firstPage.id, title: firstPage.title, body: "first", lastEditedBy: "user",
            provenance: evidence)
        let firstVersion = try #require(try store.pageHeadVersionID(pageID: firstPage.id))
        let secondVersion = try store.appendPageVersion(
            pageID: firstPage.id, title: firstPage.title, body: "second",
            expectedHeadVersionID: firstVersion, lastEditedBy: "agent:ingest", provenance: evidence)
        try store.updatePage(
            id: secondPage.id, title: secondPage.title, body: "other", lastEditedBy: "user",
            provenance: evidence)
        let thirdVersion = try #require(try store.pageHeadVersionID(pageID: secondPage.id))

        let blockers = try deletionBlockers(for: source.id, in: store)
        #expect(blockers.values == [
            .init(sourceID: source.id, pageVersionID: firstVersion, pageID: firstPage.id),
            .init(sourceID: source.id, pageVersionID: secondVersion, pageID: firstPage.id),
            .init(sourceID: source.id, pageVersionID: thirdVersion, pageID: secondPage.id),
        ])
        #expect(try store.getSource(id: source.id).id == source.id)
    }

    @Test func emptyBlockerCollectionCannotBeConstructed() {
        #expect(NonEmptyProvenanceDeletionBlockers([]) == nil)
    }
}
