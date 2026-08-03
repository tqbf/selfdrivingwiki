#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore

@MainActor
struct WikiStoreModelBookmarkMutationTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-bm-mutation-\(UUID().uuidString).sqlite")
    }

    @Test func renameBookmarkNodePropagatesStoreFailures() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        let page = try store.createPage(title: "Page")
        let reference = try store.createBookmarkNode(
            parentID: nil,
            position: 0,
            content: .page(page.id)
        )
        let model = WikiStoreModel(store: store)

        do {
            try model.renameBookmarkNode(id: reference.id, to: "Renamed")
            Issue.record("Expected renameBookmarkNode to throw for a non-folder bookmark")
        } catch let WikiStoreError.invalidBookmarkRow(id, reason) {
            #expect(id == reference.id.rawValue)
            #expect(reason == "only folders can be renamed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
#endif
