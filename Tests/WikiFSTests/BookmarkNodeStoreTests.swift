import Testing
import Foundation
import SQLite3
@testable import WikiFSCore

/// Store-level tests for the bookmark_nodes table (v16): schema migration, CRUD,
/// cascade delete, position renumbering, move/reorder, and stale ref handling.
@Suite struct BookmarkNodeStoreTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmarks-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - Schema migration (AC.1)

    @Test func freshDBHasBookmarkNodesTable() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "25")

        // The table exists.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.isEmpty)
    }

    @Test func migratedDBPreservesExistingData() throws {
        let url = tempDatabaseURL()
        // Create a v15 DB by writing pages + sources, then reopen (it will
        // migrate v15→v16 on open).
        let store = try SQLiteWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Test Page")
        _ = try store.addSource(filename: "test.txt", data: Data("hello".utf8))
        _ = page

        // Reopen — triggers migration to v16.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        #expect(reopened.pragmaValue("user_version") == "25")

        // Existing data is intact.
        let pages = try reopened.listPages(sortBy: .lastUpdated)
        #expect(pages.count == 1)
        #expect(pages.first?.title == "Test Page")

        let sources = try reopened.listSources()
        #expect(sources.count == 1)

        // bookmark_nodes table exists and is empty.
        let nodes = try reopened.listBookmarkNodes()
        #expect(nodes.isEmpty)
    }

    // MARK: - Folder CRUD (AC.2)

    @Test func createFolderAtRoot() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "My Folder", targetID: nil)
        #expect(folder.kind == .folder)
        #expect(folder.label == "My Folder")
        #expect(folder.parentID == nil)
        #expect(folder.position == 0)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.id == folder.id)
    }

    @Test func createNestedFolder() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Parent", targetID: nil)
        let child = try store.createBookmarkNode(
            parentID: parent.id, position: 0, kind: .folder,
            label: "Child", targetID: nil)
        #expect(child.parentID == parent.id)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 2)
    }

    @Test func renameFolder() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Old", targetID: nil)
        try store.updateBookmarkNode(id: folder.id, label: "New")

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.first?.label == "New")
    }

    @Test func deleteFolderCascadesChildren() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Parent", targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: parent.id, position: 0, kind: .folder,
            label: "Child", targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder,
            label: "Sibling", targetID: nil)

        try store.deleteBookmarkNode(id: parent.id)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.label == "Sibling")
    }

    // MARK: - Position management

    @Test func createBookmarkNodeAtPositionShiftsSiblings() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "A",
            targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder, label: "B",
            targetID: nil)
        // Insert at position 1 → B shifts to position 2.
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder, label: "C",
            targetID: nil)

        let nodes = try store.listBookmarkNodes()
        let labels = nodes.map(\.label)
        #expect(labels == ["A", "C", "B"])
        let positions = nodes.map(\.position)
        #expect(positions == [0, 1, 2])
    }

    @Test func deleteRenumbersSiblings() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "A",
            targetID: nil)
        let b = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder, label: "B",
            targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: nil, position: 2, kind: .folder, label: "C",
            targetID: nil)

        try store.deleteBookmarkNode(id: b.id)

        let nodes = try store.listBookmarkNodes()
        let positions = nodes.map(\.position)
        #expect(positions == [0, 1])
    }

    // MARK: - Page/source ref CRUD (AC.3)

    @Test func addPageRef() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "AI")
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .pageRef,
            label: nil, targetID: page.id)
        #expect(ref.kind == .pageRef)
        #expect(ref.targetID == page.id)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.targetID == page.id)
    }

    @Test func addSourceRef() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "paper.pdf", data: Data("x".utf8))
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .sourceRef,
            label: nil, targetID: source.id)
        #expect(ref.kind == .sourceRef)
        #expect(ref.targetID == source.id)
    }

    @Test func deleteRefDoesNotDeleteTarget() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Keep Me")
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .pageRef,
            label: nil, targetID: page.id)

        try store.deleteBookmarkNode(id: ref.id)

        // Page still exists.
        let page2 = try store.getPage(id: page.id)
        #expect(page2.title == "Keep Me")

        // Bookmark node is gone.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.isEmpty)
    }

    @Test func targetDeletedRefBecomesStale() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Doomed")
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .pageRef,
            label: nil, targetID: page.id)

        // Delete the page.
        try store.deletePage(id: page.id)

        // The ref is still there (stale — not auto-deleted).
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.targetID == ref.targetID)
    }

    // MARK: - Move/reorder (AC.4)

    @Test func moveNodeToDifferentParent() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let parentA = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "A",
            targetID: nil)
        let parentB = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder, label: "B",
            targetID: nil)
        let child = try store.createBookmarkNode(
            parentID: parentA.id, position: 0, kind: .folder, label: "Child",
            targetID: nil)

        // Move child from A to B.
        try store.moveBookmarkNode(id: child.id, toParentID: parentB.id, position: 0)

        let nodes = try store.listBookmarkNodes()
        let movedChild = nodes.first { $0.id == child.id }
        #expect(movedChild?.parentID == parentB.id)
        #expect(movedChild?.position == 0)
    }

    @Test func reorderWithinParent() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "A",
            targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder, label: "B",
            targetID: nil)
        let c = try store.createBookmarkNode(
            parentID: nil, position: 2, kind: .folder, label: "C",
            targetID: nil)

        // Move C to position 0.
        try store.moveBookmarkNode(id: c.id, toParentID: nil, position: 0)

        let nodes = try store.listBookmarkNodes()
        let labels = nodes.map(\.label)
        #expect(labels == ["C", "A", "B"])
        let positions = nodes.map(\.position)
        #expect(positions == [0, 1, 2])
    }

    @Test func moveLeavesNoPositionGaps() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "Parent",
            targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: parent.id, position: 0, kind: .folder, label: "C1",
            targetID: nil)
        let c2 = try store.createBookmarkNode(
            parentID: parent.id, position: 1, kind: .folder, label: "C2",
            targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: parent.id, position: 2, kind: .folder, label: "C3",
            targetID: nil)

        // Move C2 to root.
        try store.moveBookmarkNode(id: c2.id, toParentID: nil, position: 1)

        // Remaining children of parent should be contiguous.
        let nodes = try store.listBookmarkNodes()
        let children = nodes.filter { $0.parentID == parent.id }.sorted { $0.position < $1.position }
        let positions = children.map(\.position)
        #expect(positions == [0, 1])
    }

    // MARK: - Cycle prevention (H3)

    @Test func moveIntoSelfThrows() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "F",
            targetID: nil)

        #expect(throws: WikiStoreError.self) {
            try store.moveBookmarkNode(id: folder.id, toParentID: folder.id, position: 0)
        }

        // Tree is unchanged.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.parentID == nil)
    }

    @Test func moveIntoDirectChildThrows() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "P",
            targetID: nil)
        let child = try store.createBookmarkNode(
            parentID: parent.id, position: 0, kind: .folder, label: "C",
            targetID: nil)

        // Moving parent into child → cycle.
        #expect(throws: WikiStoreError.self) {
            try store.moveBookmarkNode(id: parent.id, toParentID: child.id, position: 0)
        }

        // Hierarchy is unchanged.
        let nodes = try store.listBookmarkNodes()
        let p = nodes.first { $0.id == parent.id }
        #expect(p?.parentID == nil)
    }

    @Test func moveIntoDeepDescendantThrows() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let l1 = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "L1",
            targetID: nil)
        let l2 = try store.createBookmarkNode(
            parentID: l1.id, position: 0, kind: .folder, label: "L2",
            targetID: nil)
        let l3 = try store.createBookmarkNode(
            parentID: l2.id, position: 0, kind: .folder, label: "L3",
            targetID: nil)

        // Moving L1 into L3 (its grandchild) → cycle.
        #expect(throws: WikiStoreError.self) {
            try store.moveBookmarkNode(id: l1.id, toParentID: l3.id, position: 0)
        }

        // Hierarchy is unchanged.
        let nodes = try store.listBookmarkNodes()
        let root = nodes.first { $0.id == l1.id }
        #expect(root?.parentID == nil)
    }

    @Test func moveIntoUnrelatedFolderSucceeds() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "A",
            targetID: nil)
        let b = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder, label: "B",
            targetID: nil)

        // Moving A into B is fine — no cycle.
        try store.moveBookmarkNode(id: a.id, toParentID: b.id, position: 0)

        let nodes = try store.listBookmarkNodes()
        let moved = nodes.first { $0.id == a.id }
        #expect(moved?.parentID == b.id)
    }
}
