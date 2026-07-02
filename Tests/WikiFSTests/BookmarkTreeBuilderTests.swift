import Testing
import Foundation
@testable import WikiFSCore

/// Tests for the pure-logic tree builder (AC.5).
@Suite struct BookmarkTreeBuilderTests {

    // MARK: - Tree assembly

    @Test func buildFlatTree() {
        let nodes = [
            BookmarkNode(id: "b", parentID: nil, position: 1, kind: .folder, label: "B",
                     targetID: nil),
            BookmarkNode(id: "a", parentID: nil, position: 0, kind: .folder, label: "A",
                     targetID: nil),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 2)
        // Sorted by position.
        #expect(tree[0].node.id == "a")
        #expect(tree[1].node.id == "b")
    }

    @Test func buildNestedTree() {
        let nodes = [
            BookmarkNode(id: "parent", parentID: nil, position: 0, kind: .folder, label: "P",
                     targetID: nil),
            BookmarkNode(id: "child", parentID: "parent", position: 0, kind: .folder, label: "C",
                     targetID: nil),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 1)
        #expect(tree[0].node.id == "parent")
        #expect(tree[0].children?.count == 1)
        #expect(tree[0].children?.first?.node.id == "child")
    }

    @Test func emptyFolderHasEmptyArrayChildren() {
        let nodes = [
            BookmarkNode(id: "empty", parentID: nil, position: 0, kind: .folder, label: "E",
                     targetID: nil),
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
            BookmarkNode(id: "ref", parentID: nil, position: 0, kind: .pageRef, label: nil,
                     targetID: PageID(rawValue: "page1")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree.count == 1)
        // Page refs are leaves — children == nil.
        #expect(tree[0].children == nil)
    }

    @Test func folderWithChildrenRendersRecursively() {
        let nodes = [
            BookmarkNode(id: "l1", parentID: nil, position: 0, kind: .folder, label: "L1",
                     targetID: nil),
            BookmarkNode(id: "l2", parentID: "l1", position: 0, kind: .folder, label: "L2",
                     targetID: nil),
            BookmarkNode(id: "l3", parentID: "l2", position: 0, kind: .folder, label: "L3",
                     targetID: nil),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree[0].node.id == "l1")
        #expect(tree[0].children?[0].node.id == "l2")
        #expect(tree[0].children?[0].children?[0].node.id == "l3")
    }

    // MARK: - Selection

    @Test func pageRefSelection() {
        let nodes = [
            BookmarkNode(id: "ref", parentID: nil, position: 0, kind: .pageRef, label: nil,
                     targetID: PageID(rawValue: "p1")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        // Selection is always .bookmark(nodeID) — does NOT open a tab.
        #expect(tree[0].selection == .bookmark("ref"))
        // openSelection returns the target page for double-click / "Open".
        #expect(tree[0].openSelection == .page(PageID(rawValue: "p1")))
    }

    @Test func sourceRefSelection() {
        let nodes = [
            BookmarkNode(id: "ref", parentID: nil, position: 0, kind: .sourceRef, label: nil,
                     targetID: PageID(rawValue: "s1")),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree[0].selection == .bookmark("ref"))
        #expect(tree[0].openSelection == .source(PageID(rawValue: "s1")))
    }

    @Test func folderHasBookmarkSelection() {
        let nodes = [
            BookmarkNode(id: "f", parentID: nil, position: 0, kind: .folder, label: "F",
                     targetID: nil),
        ]
        let tree = buildBookmarkTree(nodes: nodes)
        #expect(tree[0].selection == .bookmark("f"))
    }
}
