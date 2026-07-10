import Testing
import Foundation
@testable import WikiFSCore

/// Regression coverage for issue #238: bookmark mutation failures (e.g. a
/// concurrent ingest process holding the DB long enough to trip the store's
/// busy_timeout) must surface via `WikiStoreModel.storeError`, not vanish into
/// `DebugLog` as a silent no-op.
@MainActor
struct BookmarkMutationErrorSurfaceTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-error-surface-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    @Test func moveBookmarkNodeFailureSetsStoreError() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let model = WikiStoreModel(store: store)

        #expect(model.storeError == nil)

        // Moving a node that doesn't exist throws WikiStoreError.unexpected —
        // previously only logged, now must surface as a user-facing alert.
        let ok = model.moveBookmarkNode(id: "missing-node", toParentID: nil, position: 0)

        #expect(ok == false)
        #expect(model.storeError != nil)
        #expect(model.storeError?.title == "Couldn't Update Bookmarks")
    }

    @Test func successfulMutationLeavesStoreErrorUntouched() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "One")
        let model = WikiStoreModel(store: store)

        model.addPageRef(parentID: nil, pageID: page.id)

        #expect(model.storeError == nil)
        #expect(model.bookmarkNodes.count == 1)
    }
}
