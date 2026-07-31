import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

struct PageVersionSourceWriterTests {
    @Test func createPageSeedsMirrorAtInitialVersion() throws {
        let store = try TestStoreFactory.inMemory()

        let page = try store.createPage(title: "Seed")

        #expect(page.version == 1)
        #expect(try store.getPage(id: page.id).version == 1)
    }

    @Test func createEmptyPageHasNoSources() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Empty")
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        #expect(try store.pageVersionSources(versionID: head).isEmpty)
    }

    @Test func mainUpdateWritesSourcesAtomically() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Evidence")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        try store.updatePage(
            id: page.id, title: page.title, body: "Claim", lastEditedBy: "user",
            provenance: [.init(sourceID: source.id, role: .primary)]
        )

        #expect(try store.pageHeadSources(pageID: page.id) == [
            .init(
                pageVersionID: try #require(try store.pageHeadVersionID(pageID: page.id)),
                sourceID: source.id, role: .primary),
        ])
    }

    @Test func workspaceExistingPageWritesEdges() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Workspace evidence")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let workspaceID = try store.createWorkspace(name: nil, activityID: nil)

        let versionID = try #require(try store.workspaceWritePage(
            workspaceID: workspaceID, pageID: page.id, title: page.title, body: "Workspace claim",
            author: "user", provenance: [.init(sourceID: source.id, role: .supporting)]))

        #expect(try store.pageVersionSources(versionID: versionID).map(\.sourceID) == [source.id])
    }

    @Test func pageUpsertFirstVersionGetsSources() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        let outcome = try PageUpsert.upsert(
            in: store, id: nil, title: "Initial evidence", body: "Claim", author: "user",
            provenance: [.init(sourceID: source.id, role: .primary)])

        let history = try store.pageVersionHistory(pageID: outcome.id)
        #expect(history.count == 1)
        #expect(try store.pageVersionSources(versionID: try #require(history.first?.id)).map(\.sourceID) == [source.id])
    }

    @Test func workspaceMintCopiesStagedSources() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let workspaceID = try store.createWorkspace(name: nil, activityID: nil)
        let stagedPageID = PageID(rawValue: ULID.generate())

        #expect(try store.workspaceWritePage(
            workspaceID: workspaceID, pageID: stagedPageID, title: "Staged evidence", body: "Claim",
            author: "user", provenance: [.init(sourceID: source.id, role: .primary)]) == nil)
        _ = try store.workspaceMerge(workspaceID: workspaceID)

        let head = try #require(try store.pageHeadVersionID(pageID: stagedPageID))
        #expect(try store.pageVersionSources(versionID: head).map(\.sourceID) == [source.id])
    }

    @Test func casFailureWritesNothing() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "CAS")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let before = try #require(try store.pageHeadVersionID(pageID: page.id))

        #expect(throws: PageConflictError.self) {
            _ = try store.appendPageVersion(
                pageID: page.id, title: page.title, body: "new",
                expectedHeadVersionID: PageVersionID(rawValue: "stale"),
                provenance: [.init(sourceID: source.id, role: .primary)]
            )
        }

        #expect(try store.pageHeadVersionID(pageID: page.id) == before)
        #expect(try store.pageVersionSources(versionID: before).isEmpty)
    }

    @Test func duplicateExactSourceRoleInputWritesNothingAndEmitsNothing() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Duplicate")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let before = try #require(try store.pageHeadVersionID(pageID: page.id))
        let input = PageVersionSourceInput(sourceID: source.id, role: .supporting)

        #expect(throws: PageVersionProvenanceWriteError.self) {
            try store.updatePage(
                id: page.id, title: page.title, body: "new", lastEditedBy: "user",
                provenance: [input, input]
            )
        }

        #expect(try store.pageHeadVersionID(pageID: page.id) == before)
    }

    @Test func sameSourceWithDifferentRolesIsAccepted() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Roles")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))

        try store.updatePage(
            id: page.id, title: page.title, body: "new", lastEditedBy: "user",
            provenance: [
                .init(sourceID: source.id, role: .supporting),
                .init(sourceID: source.id, role: .quoted),
            ]
        )

        #expect(try store.pageHeadSources(pageID: page.id).map(\.role) == [.supporting, .quoted])
    }

    @Test func wikictlCASWritesSources() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "CLI")
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        _ = try PageCommand.run(
            .add(
                id: page.id, title: page.title, body: .inline("new"),
                expectHead: head, provenance: [.init(sourceID: source.id, role: .primary)]),
            in: store
        )

        #expect(try store.pageHeadSources(pageID: page.id).map(\.sourceID) == [source.id])
    }
}
