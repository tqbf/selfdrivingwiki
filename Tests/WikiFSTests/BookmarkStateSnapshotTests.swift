import Testing
import Foundation
@testable import WikiFSCore

/// Tests for the bookmark tree section in `WikiStateSnapshot.renderStateFile()`
/// and the `renderBookmarkTree` helper (#239).
@Suite struct BookmarkStateSnapshotTests {

    // MARK: - renderBookmarkTree

    @Test func emptyBookmarksShowsNoBookmarksYet() {
        let snapshot = WikiStateSnapshot.make(
            allTitles: ["Page A"], indexBody: "", logLines: [], bookmarkNodes: []
        )
        let md = snapshot.renderStateFile()
        #expect(md.contains("## Bookmarks"))
        #expect(md.contains("No bookmarks yet."))
    }

    @Test func rootFolderRendersWithLabel() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "f1"), parentID: nil, position: 0, content: .folder(label: "Research")),
        ]
        let tree = WikiStateSnapshot.renderBookmarkTree(nodes)
        #expect(tree.contains("📁 Research"))
    }

    @Test func nestedFoldersRenderIndented() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "root"), parentID: nil, position: 0, content: .folder(label: "Root")),
            BookmarkNode(id: BookmarkID(rawValue: "child"), parentID: BookmarkID(rawValue: "root"), position: 0, content: .folder(label: "Child")),
        ]
        let tree = WikiStateSnapshot.renderBookmarkTree(nodes)
        let lines = tree.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].contains("Root"))
        #expect(!lines[0].hasPrefix("  "))  // Root at depth 0
        #expect(lines[1].hasPrefix("  "))    // Child at depth 1
        #expect(lines[1].contains("Child"))
    }

    @Test func pageRefRendersWithTargetID() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "p1"), parentID: nil, position: 0, content: .page(PageID(rawValue: "01PAGE"))),
        ]
        let tree = WikiStateSnapshot.renderBookmarkTree(nodes)
        #expect(tree.contains("📄"))
        #expect(tree.contains("page:01PAGE"))
    }

    @Test func sourceRefRendersWithTargetID() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "s1"), parentID: nil, position: 0, content: .source(SourceID(rawValue: "01SRC"))),
        ]
        let tree = WikiStateSnapshot.renderBookmarkTree(nodes)
        #expect(tree.contains("source:01SRC"))
    }

    @Test func chatRefRendersWithTargetID() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "c1"), parentID: nil, position: 0, content: .chat(ChatID(rawValue: "01CHAT"))),
        ]
        let tree = WikiStateSnapshot.renderBookmarkTree(nodes)
        #expect(tree.contains("chat:01CHAT"))
    }

    @Test func mixedTreeRendersInOrder() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "f1"), parentID: nil, position: 0, content: .folder(label: "Research")),
            BookmarkNode(id: BookmarkID(rawValue: "p1"), parentID: BookmarkID(rawValue: "f1"), position: 1, content: .page(PageID(rawValue: "01PAGE"))),
            BookmarkNode(id: BookmarkID(rawValue: "p2"), parentID: BookmarkID(rawValue: "f1"), position: 0, content: .page(PageID(rawValue: "02PAGE"))),
            BookmarkNode(id: BookmarkID(rawValue: "f2"), parentID: nil, position: 1, content: .folder(label: "Notes")),
        ]
        let tree = WikiStateSnapshot.renderBookmarkTree(nodes)
        let lines = tree.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Root has 2 folders, f1 first (position 0), f2 second (position 1)
        #expect(lines[0].contains("Research"))
        #expect(lines[1].hasPrefix("  "))  // child of Research
        #expect(lines[2].hasPrefix("  "))  // child of Research
        // p2 should come before p1 (position 0 < position 1)
        #expect(lines[1].contains("02PAGE"))
        #expect(lines[2].contains("01PAGE"))
        #expect(lines[3].contains("Notes"))
    }

    @Test func bookmarkSectionIncludedInStateFile() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "f1"), parentID: nil, position: 0, content: .folder(label: "Research")),
        ]
        let snapshot = WikiStateSnapshot.make(
            allTitles: ["Page A"], indexBody: "", logLines: [],
            bookmarkNodes: nodes
        )
        let md = snapshot.renderStateFile()
        #expect(md.contains("## Bookmarks"))
        #expect(md.contains("Research"))
        #expect(md.contains("wikictl bookmark"))
    }
}
