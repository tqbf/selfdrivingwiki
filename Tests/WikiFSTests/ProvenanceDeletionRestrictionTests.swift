import Foundation
import Testing
@testable import WikiFSCore

struct ProvenanceDeletionRestrictionTests {
    private func recorder(for store: GRDBWikiStore) -> SignalRecorder {
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "provenance-tests"))
        store.eventBus = bus
        let recorder = SignalRecorder()
        bus.subscribe(nil) { recorder.append($0) }
        return recorder
    }
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

    @Test func unreferencedSourceDeletionSucceedsAndEmitsOnce() async throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "orphan.txt", data: Data("orphan".utf8))
        let events = recorder(for: store)

        try store.deleteSource(id: source.id)

        #expect(throws: WikiStoreError.self) { try store.getSource(id: source.id) }
        try await events.awaitNonEmpty()
        #expect(events.snapshot.count == 1)
        #expect(events.snapshot.first?.kind == .source)
        #expect(events.snapshot.first?.change == .deleted)
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

    @Test func multipleVersionsOfOnePageRemainDistinctBlockers() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let page = try store.createPage(title: "One")
        let input = [PageVersionSourceInput(sourceID: source.id, role: .supporting)]
        try store.updatePage(id: page.id, title: page.title, body: "v1", lastEditedBy: "writer-a", provenance: input)
        let first = try #require(try store.pageHeadVersionID(pageID: page.id))
        let second = try store.appendPageVersion(pageID: page.id, title: page.title, body: "v2", expectedHeadVersionID: first, lastEditedBy: "writer-b", provenance: input)

        #expect(try deletionBlockers(for: source.id, in: store).values.map(\.pageVersionID) == [first, second])
    }

    @Test func multiplePagesReturnAllBlockers() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let first = try store.createPage(title: "A")
        let second = try store.createPage(title: "B")
        let input = [PageVersionSourceInput(sourceID: source.id, role: .primary)]
        try store.updatePage(id: first.id, title: first.title, body: "a", lastEditedBy: "a", provenance: input)
        try store.updatePage(id: second.id, title: second.title, body: "b", lastEditedBy: "b", provenance: input)

        #expect(Set(try deletionBlockers(for: source.id, in: store).values.map(\.pageID)) == Set([first.id, second.id]))
    }

    @Test func duplicateJoinedRowsDeduplicateByFullTypedIdentity() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let page = try store.createPage(title: "Roles")
        try store.updatePage(
            id: page.id, title: page.title, body: "claim", lastEditedBy: "writer",
            provenance: [.init(sourceID: source.id, role: .primary), .init(sourceID: source.id, role: .quoted)])

        #expect(try deletionBlockers(for: source.id, in: store).values.count == 1)
    }

    @Test func blockersOrderByPageThenVersionThenSourceID() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let page = try store.createPage(title: "Ordered")
        let input = [PageVersionSourceInput(sourceID: source.id, role: .primary)]
        try store.updatePage(id: page.id, title: page.title, body: "one", lastEditedBy: "a", provenance: input)
        let first = try #require(try store.pageHeadVersionID(pageID: page.id))
        let second = try store.appendPageVersion(pageID: page.id, title: page.title, body: "two", expectedHeadVersionID: first, lastEditedBy: "b", provenance: input)
        let values = try deletionBlockers(for: source.id, in: store).values

        #expect(values == values.sorted { ($0.pageID.rawValue, $0.pageVersionID.rawValue, $0.sourceID.rawValue) < ($1.pageID.rawValue, $1.pageVersionID.rawValue, $1.sourceID.rawValue) })
        #expect(values.map(\.pageVersionID) == [first, second])
    }

    @Test func typedBlockersIncludeSourcePageVersionAndOwningPageIDs() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let page = try store.createPage(title: "Typed")
        try store.updatePage(id: page.id, title: page.title, body: "claim", lastEditedBy: "writer", provenance: [.init(sourceID: source.id, role: .primary)])
        let version = try #require(try store.pageHeadVersionID(pageID: page.id))
        let blocker = try #require(try deletionBlockers(for: source.id, in: store).values.first)

        #expect(blocker.sourceID == source.id)
        #expect(blocker.pageID == page.id)
        #expect(blocker.pageVersionID == version)
    }

    @Test func restrictedDeletionDoesNotDeleteSourceOrAnyProvenanceEdge() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let page = try store.createPage(title: "Safe")
        try store.updatePage(id: page.id, title: page.title, body: "claim", lastEditedBy: "writer", provenance: [.init(sourceID: source.id, role: .primary)])
        let version = try #require(try store.pageHeadVersionID(pageID: page.id))

        _ = try deletionBlockers(for: source.id, in: store)
        #expect(try store.getSource(id: source.id).id == source.id)
        #expect(try store.pageVersionSources(versionID: version).map(\.sourceID) == [source.id])
    }

    @Test func restrictedDeletionWritesNothingAndEmitsNothing() async throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let page = try store.createPage(title: "Quiet")
        try store.updatePage(id: page.id, title: page.title, body: "claim", lastEditedBy: "writer", provenance: [.init(sourceID: source.id, role: .primary)])
        let version = try #require(try store.pageHeadVersionID(pageID: page.id))
        let events = recorder(for: store)

        _ = try deletionBlockers(for: source.id, in: store)
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(events.snapshot.isEmpty)
        #expect(try store.getSource(id: source.id).id == source.id)
        #expect(try store.pageVersionSources(versionID: version).count == 1)
    }

    @Test func fullBlockerCollectionMapsToIssue219ProvenanceCategory() throws {
        let blocker = ProvenanceDeletionBlocker(sourceID: SourceID(rawValue: "s"), pageVersionID: PageVersionID(rawValue: "v"), pageID: PageID(rawValue: "p"))
        let blockers = try #require(NonEmptyProvenanceDeletionBlockers([blocker]))
        #expect(blockers.issue219DeletionAnalysisInput == .provenance(blockers))
    }

    @Test func issue219MappingPreservesOrderAndEveryBlockerIdentity() throws {
        let first = ProvenanceDeletionBlocker(sourceID: SourceID(rawValue: "s1"), pageVersionID: PageVersionID(rawValue: "v1"), pageID: PageID(rawValue: "p1"))
        let second = ProvenanceDeletionBlocker(sourceID: SourceID(rawValue: "s2"), pageVersionID: PageVersionID(rawValue: "v2"), pageID: PageID(rawValue: "p2"))
        let blockers = try #require(NonEmptyProvenanceDeletionBlockers([first, second]))
        guard case .provenance(let mapped) = blockers.issue219DeletionAnalysisInput else {
            Issue.record("expected provenance Issue #219 input")
            return
        }
        #expect(mapped.ordered == [first, second])
    }

    @Test func emptyBlockerCollectionCannotBeConstructed() {
        #expect(NonEmptyProvenanceDeletionBlockers([]) == nil)
    }

    @Test func nonEmptyBlockersExposeTheirPersistenceOrder() {
        let blocker = ProvenanceDeletionBlocker(
            sourceID: SourceID(rawValue: "source"),
            pageVersionID: PageVersionID(rawValue: "version"),
            pageID: PageID(rawValue: "page"))

        #expect(NonEmptyProvenanceDeletionBlockers([blocker])?.ordered == [blocker])
    }
}
