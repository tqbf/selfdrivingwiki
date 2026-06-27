import Foundation
import Testing
@testable import WikiFS

/// Tests for `EditableTitle.committedValue` — the pure rule that decides whether
/// an inline title edit is a real rename worth committing.
@MainActor
struct EditableTitleTests {

    @Test func commitsTrimmedChangedTitle() {
        #expect(EditableTitle.committedValue(draft: "  New Name  ", current: "Old") == "New Name")
    }

    @Test func skipsUnchangedTitle() {
        #expect(EditableTitle.committedValue(draft: "Same", current: "Same") == nil)
    }

    @Test func skipsUnchangedAfterTrim() {
        // Re-committing the same title with stray whitespace is not a rename.
        #expect(EditableTitle.committedValue(draft: "  Same  ", current: "Same") == nil)
    }

    @Test func skipsEmptyOrWhitespaceOnly() {
        #expect(EditableTitle.committedValue(draft: "", current: "Old") == nil)
        #expect(EditableTitle.committedValue(draft: "   ", current: "Old") == nil)
    }

    @Test func renamingFromBlankTitleCommits() {
        #expect(EditableTitle.committedValue(draft: "First Title", current: "") == "First Title")
    }
}
