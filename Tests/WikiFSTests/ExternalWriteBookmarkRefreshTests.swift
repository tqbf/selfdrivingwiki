#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
@testable import WikiFSCore

/// Regression suite for issue #416: external bookmark writes (agent / `wikictl`)
/// not refreshing the Bookmarks sidebar until app restart.
///
/// `WikiStoreModel.reloadFromStore()` — the path triggered by cross-process
/// writes — must call `reloadBookmarkNodes()` so that bookmark changes made
/// directly against the store (bypassing the model's local mutators) appear in
/// `model.bookmarkNodes`, which `BookmarksContainerView` / `BookmarksOutlineView`
/// observe.
@MainActor
struct ExternalWriteBookmarkRefreshTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ext-bm-\(UUID().uuidString).sqlite")
    }

    private func makeModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        return (model, store)
    }

    @Test func reloadFromStoreRefreshesBookmarksAfterExternalCreateFolder() throws {
        let (model, store) = try makeModel()
        #expect(model.bookmarkNodes.isEmpty)

        // Simulate a wikictl / agent write: create a folder directly through the
        // store, bypassing the model's local createFolder() mutator (which calls
        // reloadBookmarkNodes() itself).
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Test Folder", targetID: nil)

        // The model's bookmarkNodes is still stale — the store write doesn't
        // touch the model's memo.
        #expect(model.bookmarkNodes.isEmpty)

        // reloadFromStore() is what the bus handler calls after a Darwin
        // notification; it must now pick up the bookmark change.
        model.reloadFromStore()

        #expect(model.bookmarkNodes.count == 1)
        let node = model.bookmarkNodes[0]
        #expect(node.kind == .folder)
        #expect(node.label == "Test Folder")
        #expect(node.parentID == nil)
    }

    @Test func reloadFromStoreRefreshesBookmarksAfterExternalAddRef() throws {
        let (model, store) = try makeModel()

        // Create a page to reference.
        model.newPage(title: "A Page")
        guard case .page(let pageID) = model.selection else {
            Issue.record("expected page selection"); return
        }

        // Agent creates a folder + page ref directly through the store.
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Research", targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: folder.id, position: 0, kind: .pageRef,
            label: nil, targetID: pageID)

        model.reloadFromStore()

        #expect(model.bookmarkNodes.count == 2)
        let refs = model.bookmarkNodes.filter { $0.kind == .pageRef }
        #expect(refs.count == 1)
        #expect(refs[0].targetID == pageID)
        #expect(refs[0].parentID == folder.id)
    }

    @Test func reloadFromStoreRefreshesBookmarksAfterExternalRename() throws {
        let (model, store) = try makeModel()

        // Agent creates a folder, then renames it — all through the store.
        let node = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Old Name", targetID: nil)
        try store.updateBookmarkNode(id: node.id, label: "New Name")

        model.reloadFromStore()

        #expect(model.bookmarkNodes.count == 1)
        #expect(model.bookmarkNodes[0].label == "New Name")
    }

    @Test func reloadFromStoreRefreshesBookmarksAfterExternalDelete() throws {
        let (model, store) = try makeModel()

        // Seed the model with a folder via the store, then reload.
        _ = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Doomed", targetID: nil)
        model.reloadFromStore()
        #expect(model.bookmarkNodes.count == 1)

        // Agent deletes it directly through the store.
        try store.deleteBookmarkNode(id: model.bookmarkNodes[0].id)

        model.reloadFromStore()
        #expect(model.bookmarkNodes.isEmpty)
    }

    @Test func reloadFromStoreRefreshesBookmarksAfterExternalMove() throws {
        let (model, store) = try makeModel()

        // Create two folders + a page ref under the first folder.
        let folderA = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Folder A", targetID: nil)
        let folderB = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .folder,
            label: "Folder B", targetID: nil)
        _ = try store.createBookmarkNode(
            parentID: folderA.id, position: 0, kind: .folder,
            label: "Child", targetID: nil)

        model.reloadFromStore()
        #expect(model.bookmarkNodes.count == 3)
        let child = model.bookmarkNodes.first { $0.label == "Child" }!
        #expect(child.parentID == folderA.id)

        // Agent moves "Child" from Folder A to Folder B.
        try store.moveBookmarkNode(id: child.id, toParentID: folderB.id, position: 0)

        model.reloadFromStore()
        let movedChild = model.bookmarkNodes.first { $0.label == "Child" }!
        #expect(movedChild.parentID == folderB.id)
    }
}
#endif // os(macOS)
