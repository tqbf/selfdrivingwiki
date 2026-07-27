import Testing
import Foundation
@testable import WikiFSCore

/// Tests for `BookmarkNode.displayPath(id:in:)` — the pure folder-path helper
/// used by the bookmark-target picker to disambiguate same-named folders.
@Suite struct BookmarkNodeDisplayPathTests {

    @Test func rootFolderReturnsItsLabel() {
        let nodes = [
            BookmarkNode(id: "a", parentID: nil, position: 0, content: .folder(label: "Reading List")),
        ]
        #expect(BookmarkNode.displayPath(id: "a", in: nodes) == "Reading List")
    }

    @Test func nestedFolderJoinsParentChain() {
        let nodes = [
            BookmarkNode(id: "root", parentID: nil, position: 0, content: .folder(label: "Research")),
            BookmarkNode(id: "mid", parentID: "root", position: 0, content: .folder(label: "Papers")),
            BookmarkNode(id: "leaf", parentID: "mid", position: 0, content: .folder(label: "2026")),
        ]
        #expect(BookmarkNode.displayPath(id: "leaf", in: nodes) == "Research / Papers / 2026")
        #expect(BookmarkNode.displayPath(id: "mid", in: nodes) == "Research / Papers")
    }

    @Test func unknownIDReturnsEmptyString() {
        let nodes = [
            BookmarkNode(id: "a", parentID: nil, position: 0, content: .folder(label: "A")),
        ]
        #expect(BookmarkNode.displayPath(id: "missing", in: nodes) == "")
    }

    @Test func emptyLabelSegmentsAreSkipped() {
        // A reference has no label, so only its named parent contributes.
        let nodes = [
            BookmarkNode(id: "parent", parentID: nil, position: 0, content: .folder(label: "Parent")),
            BookmarkNode(id: "page", parentID: "parent", position: 0, content: .page(PageID(rawValue: "page"))),
        ]
        #expect(BookmarkNode.displayPath(id: "page", in: nodes) == "Parent")
    }

    @Test func parentCycleIsCappedNotInfinite() {
        // Corrupted store data: two folders pointing at each other. Must not
        // loop forever; result is non-crashing and bounded.
        let nodes = [
            BookmarkNode(id: "x", parentID: "y", position: 0, content: .folder(label: "X")),
            BookmarkNode(id: "y", parentID: "x", position: 0, content: .folder(label: "Y")),
        ]
        let path = BookmarkNode.displayPath(id: "x", in: nodes)
        #expect(!path.isEmpty)
        // Cap is 64 hops — even in the worst case the segment count is bounded.
        #expect(path.components(separatedBy: " / ").count <= 64)
    }
}
