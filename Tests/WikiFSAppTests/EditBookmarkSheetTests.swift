#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

@MainActor
struct EditBookmarkSheetTests {
    @Test func folderRenameFailureReturnsVisibleErrorInsteadOfDismiss() {
        let folder = BookmarkNode(
            id: BookmarkID(rawValue: "bookmark-folder-1"),
            parentID: nil,
            position: 0,
            content: .folder(label: "Old")
        )

        let result = EditBookmarkSheet.saveAction(
            node: folder,
            name: "New",
            selectedTarget: nil,
            renameFolder: { _ in
                throw WikiStoreError.invalidBookmarkRow(
                    id: folder.id.rawValue,
                    reason: "only folders can be renamed"
                )
            },
            retargetBookmark: { _ in }
        )

        #expect(result == .showError("Invalid bookmark row \(folder.id.rawValue): only folders can be renamed"))
    }

    @Test func folderRenameSuccessDismisses() {
        let folder = BookmarkNode(
            id: BookmarkID(rawValue: "bookmark-folder-1"),
            parentID: nil,
            position: 0,
            content: .folder(label: "Old")
        )
        var receivedName: String?

        let result = EditBookmarkSheet.saveAction(
            node: folder,
            name: "  New  ",
            selectedTarget: nil,
            renameFolder: { receivedName = $0 },
            retargetBookmark: { _ in }
        )

        #expect(receivedName == "New")
        #expect(result == .dismiss)
    }
}
#endif
