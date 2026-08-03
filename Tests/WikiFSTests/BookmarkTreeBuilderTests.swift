import Testing
import Foundation
@testable import WikiFSCore

/// Tests for the pure-logic tree builder (AC.5).
@Suite struct BookmarkTreeBuilderTests {

    // MARK: - Tree assembly

    @Test func buildFlatTree() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "b"), parentID: nil, position: 1, content: .folder(label: "B")),
            BookmarkNode(id: BookmarkID(rawValue: "a"), parentID: nil, position: 0, content: .folder(label: "A")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 2)
        // Sorted by position.
        #expect(tree[0].node.id.rawValue == "a")
        #expect(tree[1].node.id.rawValue == "b")
    }

    @Test func buildNestedTree() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "parent"), parentID: nil, position: 0, content: .folder(label: "P")),
            BookmarkNode(id: BookmarkID(rawValue: "child"), parentID: BookmarkID(rawValue: "parent"), position: 0, content: .folder(label: "C")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 1)
        #expect(tree[0].node.id.rawValue == "parent")
        #expect(tree[0].children?.count == 1)
        #expect(tree[0].children?.first?.node.id.rawValue == "child")
    }

    @Test func emptyFolderHasEmptyArrayChildren() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "empty"), parentID: nil, position: 0, content: .folder(label: "E")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 1)
        // Empty folders must have children = [] (not nil), so they render with
        // a disclosure triangle.
        #expect(tree[0].children != nil)
        #expect(tree[0].children?.isEmpty == true)
    }

    @Test func pageRefIsLeaf() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "ref"), parentID: nil, position: 0, content: .page(PageID(rawValue: "page1"))),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 1)
        // Page refs are leaves — children == nil.
        #expect(tree[0].children == nil)
    }

    @Test func folderWithChildrenRendersRecursively() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "l1"), parentID: nil, position: 0, content: .folder(label: "L1")),
            BookmarkNode(id: BookmarkID(rawValue: "l2"), parentID: BookmarkID(rawValue: "l1"), position: 0, content: .folder(label: "L2")),
            BookmarkNode(id: BookmarkID(rawValue: "l3"), parentID: BookmarkID(rawValue: "l2"), position: 0, content: .folder(label: "L3")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree[0].node.id.rawValue == "l1")
        #expect(tree[0].children?[0].node.id.rawValue == "l2")
        #expect(tree[0].children?[0].children?[0].node.id.rawValue == "l3")
    }

    // MARK: - Selection

    @Test func pageRefSelection() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "ref"), parentID: nil, position: 0, content: .page(PageID(rawValue: "p1"))),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        // Selection is always .bookmark(nodeID) — does NOT open a tab.
        #expect(tree[0].selection == .bookmark("ref"))
        // openSelection returns the target page for double-click / "Open".
        #expect(tree[0].openSelection == .page(PageID(rawValue: "p1")))
    }

    @Test func sourceRefSelection() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "ref"), parentID: nil, position: 0, content: .source(SourceID(rawValue: "s1"))),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree[0].selection == .bookmark("ref"))
        #expect(tree[0].openSelection == .source(SourceID(rawValue: "s1")))
    }

    @Test func folderHasBookmarkSelection() {
        let nodes = [
            BookmarkNode(id: BookmarkID(rawValue: "f"), parentID: nil, position: 0, content: .folder(label: "F")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree[0].selection == .bookmark("f"))
    }
}
