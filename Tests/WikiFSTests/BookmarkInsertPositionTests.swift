import Testing
import Foundation
@testable import WikiFSCore

/// Model-level tests for the `position` parameter on `addPageRef` /
/// `addSourceRef`, added so a wiki-link dragged onto the Bookmarks outline lands
/// *between* siblings (issue #169) rather than always appending at the end.
///
/// These cover the ordering contract the drop handler relies on; the AppKit
/// drag/drop wiring itself is exercised manually (it needs a live WKWebView).
@MainActor
struct BookmarkInsertPositionTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bookmark-insert-position-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// nil `position` (the default / append path) is unchanged by the new
    /// parameter — this guards the existing callers.
    @Test func addPageRefWithNilPositionAppends() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let p1 = try store.createPage(title: "One")
        let p2 = try store.createPage(title: "Two")
        let model = WikiStoreModel(store: store)

        model.addPageRef(parentID: nil, pageID: p1.id)
        model.reloadBookmarkNodes()
        model.addPageRef(parentID: nil, pageID: p2.id)
        model.reloadBookmarkNodes()

        let nodes = model.bookmarkNodes.sorted { $0.position < $1.position }
        #expect(nodes.map(\.position) == [0, 1])
        #expect(nodes.map(\.targetID) == [p1.id, p2.id])
    }

    /// Inserting at position 0 pushes the existing first node down.
    @Test func addPageRefAtPositionZeroPrepends() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let first = try store.createPage(title: "First")
        let model = WikiStoreModel(store: store)
        model.addPageRef(parentID: nil, pageID: first.id) // position 0

        let earlier = try store.createPage(title: "Earlier")
        model.addPageRef(parentID: nil, pageID: earlier.id, position: 0)
        model.reloadBookmarkNodes()

        let nodes = model.bookmarkNodes.sorted { $0.position < $1.position }
        #expect(nodes.map(\.position) == [0, 1])
        #expect(nodes.first?.targetID == earlier.id,
                "position: 0 must land before the previously-first node")
    }

    /// Inserting in the middle shifts only the nodes at/after the index.
    @Test func addPageRefAtMiddlePositionShiftsLaterSiblings() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        let model = WikiStoreModel(store: store)
        model.addPageRef(parentID: nil, pageID: a.id) // 0
        model.reloadBookmarkNodes()
        model.addPageRef(parentID: nil, pageID: b.id) // 1
        model.reloadBookmarkNodes()
        model.addPageRef(parentID: nil, pageID: c.id) // 2
        model.reloadBookmarkNodes()

        let mid = try store.createPage(title: "MID")
        model.addPageRef(parentID: nil, pageID: mid.id, position: 1)
        model.reloadBookmarkNodes()

        let nodes = model.bookmarkNodes.sorted { $0.position < $1.position }
        #expect(nodes.map(\.position) == [0, 1, 2, 3])
        // A, MID, B, C
        let titles = nodes.compactMap { $0.targetID }
            .compactMap { id in [a, b, c, mid].first { $0.id == id }?.title }
        #expect(titles == ["A", "MID", "B", "C"])
    }

    /// Source refs honor the same position contract as page refs.
    @Test func addSourceRefAtPositionInsertsBetweenSiblings() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let s1 = try store.addSource(filename: "a.pdf", data: Data("x".utf8))
        let s2 = try store.addSource(filename: "b.pdf", data: Data("y".utf8))
        let model = WikiStoreModel(store: store)
        model.addSourceRef(parentID: nil, sourceID: s1.id) // 0
        model.reloadBookmarkNodes()
        model.addSourceRef(parentID: nil, sourceID: s2.id) // 1
        model.reloadBookmarkNodes()

        let between = try store.addSource(filename: "mid.pdf", data: Data("z".utf8))
        model.addSourceRef(parentID: nil, sourceID: between.id, position: 1)
        model.reloadBookmarkNodes()

        let nodes = model.bookmarkNodes.sorted { $0.position < $1.position }
        #expect(nodes.map(\.position) == [0, 1, 2])
        #expect(nodes[1].targetID == between.id,
                "source ref inserted at position 1 must land between the two siblings")
    }

    /// A positioned insert is scoped to its folder — it must not disturb root
    /// ordering or a sibling folder's children.
    @Test func positionedInsertIsScopedToParent() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "F", targetID: nil)
        let model = WikiStoreModel(store: store)

        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.addPageRef(parentID: folder.id, pageID: a.id) // 0
        model.reloadBookmarkNodes()
        model.addPageRef(parentID: folder.id, pageID: b.id) // 1
        model.reloadBookmarkNodes()

        // Also a root-level ref, to confirm it's untouched.
        let root = try store.createPage(title: "Root")
        model.addPageRef(parentID: nil, pageID: root.id) // 0 at root

        let mid = try store.createPage(title: "MID")
        model.addPageRef(parentID: folder.id, pageID: mid.id, position: 0)
        model.reloadBookmarkNodes()

        let folderChildren = model.bookmarkNodes
            .filter { $0.parentID == folder.id }
            .sorted { $0.position < $1.position }
        #expect(folderChildren.map(\.position) == [0, 1, 2])
        #expect(folderChildren.first?.targetID == mid.id)

        let rootChildren = model.bookmarkNodes
            .filter { $0.parentID == nil && $0.kind == .pageRef }
        #expect(rootChildren.count == 1)
        #expect(rootChildren.first?.targetID == root.id)
    }

    /// Inserting past the end (a stale/out-of-range index) still yields a
    /// contiguous, correct ordering — the store's renumber pass defends this.
    @Test func outOfRangePositionClampsViaRenumber() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createPage(title: "A")
        let model = WikiStoreModel(store: store)
        model.addPageRef(parentID: nil, pageID: a.id) // 0

        let b = try store.createPage(title: "B")
        // No siblings exist beyond position 0; position 5 is out of range.
        model.addPageRef(parentID: nil, pageID: b.id, position: 5)
        model.reloadBookmarkNodes()

        let nodes = model.bookmarkNodes.sorted { $0.position < $1.position }
        #expect(nodes.map(\.position) == [0, 1],
                "renumber pass must keep positions contiguous on an out-of-range insert")
        #expect(nodes.last?.targetID == b.id)
    }
}
