import Testing
import Foundation
@testable import WikiFSCore

/// Tests for `BookmarkNode.displayPath(id:in:)` — the pure folder-path helper
/// used by the bookmark-target picker to disambiguate same-named folders.
@Suite struct BookmarkNodeDisplayPathTests {

    @Test func rootFolderReturnsItsLabel() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "a"), parentID: nil, position: 0, content: .folder(label: "Reading List")),
        ]
        #expect(BookmarkNode.displayPath(id: BookmarkID(rawValue: "a"), in: nodes) == "Reading List")
    }

    @Test func nestedFolderJoinsParentChain() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "root"), parentID: nil, position: 0, content: .folder(label: "Research")),
            BookmarkNode(id: BookmarkID(rawValue: "mid"), parentID: BookmarkID(rawValue: "root"), position: 0, content: .folder(label: "Papers")),
            BookmarkNode(id: BookmarkID(rawValue: "leaf"), parentID: BookmarkID(rawValue: "mid"), position: 0, content: .folder(label: "2026")),
        ]
        #expect(BookmarkNode.displayPath(id: BookmarkID(rawValue: "leaf"), in: nodes) == "Research / Papers / 2026")
        #expect(BookmarkNode.displayPath(id: BookmarkID(rawValue: "mid"), in: nodes) == "Research / Papers")
    }

    @Test func unknownIDReturnsEmptyString() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "a"), parentID: nil, position: 0, content: .folder(label: "A")),
        ]
        #expect(BookmarkNode.displayPath(id: BookmarkID(rawValue: "missing"), in: nodes) == "")
    }

    @Test func emptyLabelSegmentsAreSkipped() {
        // A reference has no label, so only its named parent contributes.
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "parent"), parentID: nil, position: 0, content: .folder(label: "Parent")),
            BookmarkNode(id: BookmarkID(rawValue: "page"), parentID: BookmarkID(rawValue: "parent"), position: 0, content: .page(PageID(rawValue: "page"))),
        ]
        #expect(BookmarkNode.displayPath(id: BookmarkID(rawValue: "page"), in: nodes) == "Parent")
    }

    @Test func parentCycleIsCappedNotInfinite() {
        // Corrupted store data: two folders pointing at each other. Must not
        // loop forever; result is non-crashing and bounded.
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "x"), parentID: BookmarkID(rawValue: "y"), position: 0, content: .folder(label: "X")),
            BookmarkNode(id: BookmarkID(rawValue: "y"), parentID: BookmarkID(rawValue: "x"), position: 0, content: .folder(label: "Y")),
        ]
        let path = BookmarkNode.displayPath(id: BookmarkID(rawValue: "x"), in: nodes)
        #expect(!path.isEmpty)
        // Cap is 64 hops — even in the worst case the segment count is bounded.
        #expect(path.components(separatedBy: " / ").count <= 64)
    }
}
