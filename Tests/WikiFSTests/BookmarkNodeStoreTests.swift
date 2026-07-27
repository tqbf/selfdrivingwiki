import Testing
import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
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

    private func insertBookmarkRow(
        at url: URL, id: String, kind: String, label: String?, targetID: String?
    ) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let quotedLabel = label.map { "'\($0)'" } ?? "NULL"
        let quotedTarget = targetID.map { "'\($0)'" } ?? "NULL"
        let sql = """
        INSERT INTO bookmark_nodes (id, parent_id, position, kind, label, target_id, created_at, updated_at)
        VALUES ('\(id)', NULL, 0, '\(kind)', \(quotedLabel), \(quotedTarget), 0, 0);
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func expectInvalidBookmarkRow(
        id expectedID: String? = nil,
        reason expectedReason: String? = nil,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("expected invalid bookmark row")
        } catch let error as WikiStoreError {
            guard case let .invalidBookmarkRow(id, reason) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            if let expectedID {
                #expect(id == expectedID)
            }
            if let expectedReason {
                #expect(reason == expectedReason)
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Tagged content and persisted tuple contract

    @Test func pageTargetRoundTrips() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Page")
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(page.id))
        #expect(node.content == .page(page.id))
        #expect(store.scalarText("SELECT kind || '|' || COALESCE(label, 'NULL') || '|' || target_id FROM bookmark_nodes WHERE id = '\(node.id)';") == "page_ref|NULL|\(page.id.rawValue)")
    }

    @Test func sourceTargetRoundTrips() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "source.txt", data: Data("source".utf8))
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .source(source.id))
        #expect(node.content == .source(source.id))
        #expect(store.scalarText("SELECT kind || '|' || COALESCE(label, 'NULL') || '|' || target_id FROM bookmark_nodes WHERE id = '\(node.id)';") == "source_ref|NULL|\(source.id.rawValue)")
    }

    @Test func chatTargetRoundTrips() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let chat = try store.createChat(kind: .edit, title: "Chat")
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .chat(chat.id))
        #expect(node.content == .chat(chat.id))
        #expect(store.scalarText("SELECT kind || '|' || COALESCE(label, 'NULL') || '|' || target_id FROM bookmark_nodes WHERE id = '\(node.id)';") == "chat_ref|NULL|\(chat.id.rawValue)")
    }

    @Test func folderRoundTrips() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let node = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: "Folder"))
        #expect(node.content == .folder(label: "Folder"))
        #expect(store.scalarText("SELECT kind || '|' || label || '|' || COALESCE(target_id, 'NULL') FROM bookmark_nodes WHERE id = '\(node.id)';") == "folder|Folder|NULL")
    }

    @Test func emptyFolderContentIsRejectedBeforeWrite() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        expectInvalidBookmarkRow {
            _ = try store.createBookmarkNode(parentID: nil, position: 0, content: .folder(label: ""))
        }
        #expect(try store.listBookmarkNodes().isEmpty)
    }

    @Test(arguments: [
        ("unknownKindRowIsRejected", "unknown", Optional("Label"), Optional("target")),
        ("folderWithoutLabelRowIsRejected", "folder", Optional<String>.none, Optional<String>.none),
        ("folderWithEmptyLabelRowIsRejected", "folder", Optional(""), Optional<String>.none),
        ("folderWithTargetRowIsRejected", "folder", Optional("Folder"), Optional("target")),
        ("referenceWithLabelRowIsRejected", "page_ref", Optional("Label"), Optional("target")),
        ("referenceWithoutTargetRowIsRejected", "source_ref", Optional<String>.none, Optional<String>.none),
    ]) func malformedRowsAreRejected(
        _ name: String, _ kind: String, _ label: String?, _ targetID: String?
    ) throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        try insertBookmarkRow(at: url, id: "bad-\(name)", kind: kind, label: label, targetID: targetID)
        expectInvalidBookmarkRow { _ = try store.listBookmarkNodes() }
    }

    @Test(arguments: [
        ("page_ref", "page reference requires a non-empty target_id"),
        ("source_ref", "source reference requires a non-empty target_id"),
        ("chat_ref", "chat reference requires a non-empty target_id"),
    ]) func emptyReferenceTargetsInPersistedRowsAreRejected(
        _ kind: String,
        _ expectedReason: String
    ) throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        let id = "bad-\(kind)-empty-target"
        try insertBookmarkRow(at: url, id: id, kind: kind, label: nil, targetID: "")
        expectInvalidBookmarkRow(id: id, reason: expectedReason) {
            _ = try store.listBookmarkNodes()
        }
    }

    @Test(arguments: [
        (BookmarkNodeKind.pageRef, "page reference requires a non-empty target_id"),
        (BookmarkNodeKind.sourceRef, "source reference requires a non-empty target_id"),
        (BookmarkNodeKind.chatRef, "chat reference requires a non-empty target_id"),
    ]) func emptyReferenceTargetsAreRejectedBeforeWrite(
        _ kind: BookmarkNodeKind,
        _ expectedReason: String
    ) throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let content: BookmarkNode.Content
        switch kind {
        case .pageRef:
            content = .page(PageID(rawValue: ""))
        case .sourceRef:
            content = .source(SourceID(rawValue: ""))
        case .chatRef:
            content = .chat(PageID(rawValue: ""))
        case .folder:
            Issue.record("folder is not a reference bookmark kind")
            return
        }

        expectInvalidBookmarkRow(id: "<new bookmark>", reason: expectedReason) {
            _ = try store.createBookmarkNode(parentID: nil, position: 0, content: content)
        }
        #expect(try store.listBookmarkNodes().isEmpty)
    }

    // MARK: - Schema migration (AC.1)

    @Test func freshDBHasBookmarkNodesTable() throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")

        // The table exists.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.isEmpty)
    }

    @Test func migratedDBPreservesExistingData() throws {
        let url = tempDatabaseURL()
        // Create a v15 DB by writing pages + sources, then reopen (it will
        // migrate v15→v16 on open).
        let store = try GRDBWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Test Page")
        _ = try store.addSource(filename: "test.txt", data: Data("hello".utf8))
        _ = page

        // Reopen — triggers migration to v16.
        let reopened = try GRDBWikiStore(databaseURL: url)
        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")

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
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "My Folder"))
        #expect(folder.kind == .folder)
        #expect(folder.label == "My Folder")
        #expect(folder.parentID == nil)
        #expect(folder.position == 0)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.id == folder.id)
    }

    @Test func createNestedFolder() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "Parent"))
        let child = try store.createBookmarkNode(
            parentID: parent.id, position: 0, content: .folder(label: "Child"))
        #expect(child.parentID == parent.id)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 2)
    }

    @Test func renameFolder() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "Old"))
        try store.renameBookmarkFolder(id: folder.id, to: "New")

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.first?.label == "New")
    }

    @Test func renameReferenceIsRejected() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Page")
        let reference = try store.createBookmarkNode(parentID: nil, position: 0, content: .page(page.id))
        expectInvalidBookmarkRow { try store.renameBookmarkFolder(id: reference.id, to: "Not allowed") }
        #expect(try store.listBookmarkNodes().first?.content == .page(page.id))
    }

    @Test func deleteFolderCascadesChildren() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "Parent"))
        _ = try store.createBookmarkNode(
            parentID: parent.id, position: 0, content: .folder(label: "Child"))
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "Sibling"))

        try store.deleteBookmarkNode(id: parent.id)

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.label == "Sibling")
    }

    // MARK: - Position management

    @Test func createBookmarkNodeAtPositionShiftsSiblings() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))
        // Insert at position 1 → B shifts to position 2.
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "C"))

        let nodes = try store.listBookmarkNodes()
        let labels = nodes.map(\.label)
        #expect(labels == ["A", "C", "B"])
        let positions = nodes.map(\.position)
        #expect(positions == [0, 1, 2])
    }

    @Test func deleteRenumbersSiblings() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        let b = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))
        _ = try store.createBookmarkNode(
            parentID: nil, position: 2, content: .folder(label: "C"))

        try store.deleteBookmarkNode(id: b.id)

        let nodes = try store.listBookmarkNodes()
        let positions = nodes.map(\.position)
        #expect(positions == [0, 1])
    }

    // MARK: - Page/source ref CRUD (AC.3)

    @Test func addPageRef() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "AI")
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .page(page.id))
        #expect(ref.kind == .pageRef)
        #expect(ref.content == .page(page.id))

        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.content == .page(page.id))
    }

    @Test func addSourceRef() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "paper.pdf", data: Data("x".utf8))
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .source(source.id))
        #expect(ref.kind == .sourceRef)
        #expect(ref.content == .source(source.id))
    }

    @Test func deleteRefDoesNotDeleteTarget() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Keep Me")
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .page(page.id))

        try store.deleteBookmarkNode(id: ref.id)

        // Page still exists.
        let page2 = try store.getPage(id: page.id)
        #expect(page2.title == "Keep Me")

        // Bookmark node is gone.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.isEmpty)
    }

    @Test func targetDeletedRefBecomesStale() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Doomed")
        let ref = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .page(page.id))

        // Delete the page.
        try store.deletePage(id: page.id)

        // The ref is still there (stale — not auto-deleted).
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.content == ref.content)
    }

    // MARK: - Move/reorder (AC.4)

    @Test func moveNodeToDifferentParent() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let parentA = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        let parentB = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))
        let child = try store.createBookmarkNode(
            parentID: parentA.id, position: 0, content: .folder(label: "Child"))

        // Move child from A to B.
        try store.moveBookmarkNode(id: child.id, toParentID: parentB.id, position: 0)

        let nodes = try store.listBookmarkNodes()
        let movedChild = nodes.first { $0.id == child.id }
        #expect(movedChild?.parentID == parentB.id)
        #expect(movedChild?.position == 0)
    }

    @Test func reorderWithinParent() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))
        let c = try store.createBookmarkNode(
            parentID: nil, position: 2, content: .folder(label: "C"))

        // Move C to position 0.
        try store.moveBookmarkNode(id: c.id, toParentID: nil, position: 0)

        let nodes = try store.listBookmarkNodes()
        let labels = nodes.map(\.label)
        #expect(labels == ["C", "A", "B"])
        let positions = nodes.map(\.position)
        #expect(positions == [0, 1, 2])
    }

    @Test func moveLeavesNoPositionGaps() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "Parent"))
        _ = try store.createBookmarkNode(
            parentID: parent.id, position: 0, content: .folder(label: "C1"))
        let c2 = try store.createBookmarkNode(
            parentID: parent.id, position: 1, content: .folder(label: "C2"))
        _ = try store.createBookmarkNode(
            parentID: parent.id, position: 2, content: .folder(label: "C3"))

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
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "F"))

        #expect(throws: WikiStoreError.self) {
            try store.moveBookmarkNode(id: folder.id, toParentID: folder.id, position: 0)
        }

        // Tree is unchanged.
        let nodes = try store.listBookmarkNodes()
        #expect(nodes.count == 1)
        #expect(nodes.first?.parentID == nil)
    }

    @Test func moveIntoDirectChildThrows() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let parent = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "P"))
        let child = try store.createBookmarkNode(
            parentID: parent.id, position: 0, content: .folder(label: "C"))

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
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let l1 = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "L1"))
        let l2 = try store.createBookmarkNode(
            parentID: l1.id, position: 0, content: .folder(label: "L2"))
        let l3 = try store.createBookmarkNode(
            parentID: l2.id, position: 0, content: .folder(label: "L3"))

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
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        let b = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))

        // Moving A into B is fine — no cycle.
        try store.moveBookmarkNode(id: a.id, toParentID: b.id, position: 0)

        let nodes = try store.listBookmarkNodes()
        let moved = nodes.first { $0.id == a.id }
        #expect(moved?.parentID == b.id)
    }

    // MARK: - Timestamps (issue #242)

    @Test func createBookmarkNodeStampsCreatedAtAndUpdatedAt() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let before = Date().addingTimeInterval(-1)
        let node = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "F"))
        let after = Date().addingTimeInterval(1)

        // Create stamps both timestamps equally, ~now.
        #expect(node.createdAt == node.updatedAt)
        #expect(node.createdAt > before)
        #expect(node.createdAt < after)

        // Persisted identically (round-trips through listBookmarkNodes).
        let reloaded = try store.listBookmarkNodes().first { $0.id == node.id }
        #expect(reloaded?.createdAt == node.createdAt)
        #expect(reloaded?.updatedAt == node.updatedAt)
    }

    @Test func updateBookmarkNodeBumpsUpdatedAtNotCreatedAt() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let node = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "Old"))
        let originalCreatedAt = node.createdAt

        try store.renameBookmarkFolder(id: node.id, to: "New")

        let reloaded = try store.listBookmarkNodes().first { $0.id == node.id }!
        #expect(reloaded.label == "New")
        #expect(reloaded.createdAt == originalCreatedAt)
        #expect(reloaded.updatedAt > originalCreatedAt)
    }

    @Test func moveAcrossParentBumpsUpdatedAt() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        let parentA = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        let parentB = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))
        let child = try store.createBookmarkNode(
            parentID: parentA.id, position: 0, content: .folder(label: "C"))
        let originalUpdatedAt = child.updatedAt

        // Cross-folder move → updatedAt bumps.
        try store.moveBookmarkNode(id: child.id, toParentID: parentB.id, position: 0)

        let reloaded = try store.listBookmarkNodes().first { $0.id == child.id }!
        #expect(reloaded.parentID == parentB.id)
        #expect(reloaded.updatedAt > originalUpdatedAt)
    }

    @Test func reorderWithinSameParentDoesNotBumpUpdatedAt() throws {
        let store = try GRDBWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, content: .folder(label: "A"))
        _ = try store.createBookmarkNode(
            parentID: nil, position: 1, content: .folder(label: "B"))
        let c = try store.createBookmarkNode(
            parentID: nil, position: 2, content: .folder(label: "C"))
        let originalUpdatedAt = c.updatedAt

        // Pure same-parent reorder (C → position 0) leaves updatedAt untouched.
        try store.moveBookmarkNode(id: c.id, toParentID: nil, position: 0)

        let reloaded = try store.listBookmarkNodes().first { $0.id == c.id }!
        #expect(reloaded.position == 0)
        #expect(reloaded.updatedAt == originalUpdatedAt)
    }
}
