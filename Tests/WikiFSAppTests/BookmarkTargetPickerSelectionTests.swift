#if os(macOS)
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `BookmarkTargetPickerSheet.parentID(forSelection:)` — the
/// `BookmarkFolderSelection` → parentID mapping. Root and a deselected picker
/// map to `nil` (top level); a folder maps to its id (#243).
@MainActor
@Suite struct BookmarkTargetPickerSelectionTests {

    @Test func rootSelectionMapsToNilParentID() {
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: .root) == nil)
    }

    @Test func folderSelectionMapsToItsID() {
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: .folder("01HZXAMPLE000FOLDER")) == "01HZXAMPLE000FOLDER")
    }

    @Test func nilSelectionMapsToNil() {
        // When the user taps to deselect everything, nil stays nil.
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: nil) == nil)
    }

    @Test func rootDoesNotCollideWithFolderOfSameString() {
        // The case tag — not a string comparison — distinguishes root from a
        // folder whose id happens to spell the old sentinel. This is the bug
        // class the enum exists to close.
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: .root) == nil)
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: .folder("__bookmarks_root__")) == "__bookmarks_root__")
    }
}
#endif
