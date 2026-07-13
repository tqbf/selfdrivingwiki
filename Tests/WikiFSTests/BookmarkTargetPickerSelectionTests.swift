import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `BookmarkTargetPickerSheet.parentID(forSelection:)` — the
/// sentinel-to-nil conversion that lets the picker offer a "Bookmarks" root
/// destination (parentID == nil) alongside real folders (#243).
@Suite struct BookmarkTargetPickerSelectionTests {

    @Test func rootSentinelMapsToNilParentID() {
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: "__bookmarks_root__") == nil)
    }

    @Test func realFolderIDPassesThrough() {
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: "01HZXAMPLE000FOLDER") == "01HZXAMPLE000FOLDER")
    }

    @Test func nilSelectionPassesThroughAsNil() {
        // When the user taps to deselect everything, nil stays nil.
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: nil) == nil)
    }

    @Test func emptyStringPassesThrough() {
        // Edge case: an empty (but non-nil) selection is not the sentinel.
        #expect(BookmarkTargetPickerSheet.parentID(forSelection: "") == "")
    }
}
