#if os(macOS)
import Testing
@testable import WikiFS
@testable import WikiFSEngine
import WikiFSCore

/// Tests for `BookmarksContainerView.filterNodes` — the pure substring search
/// over bookmark nodes (folder labels + resolved ref titles), with ancestor
/// expansion so hits inside nested folders are visible (#240).
@Suite struct BookmarksSearchTests {

    // MARK: - Helpers

    private func folder(_ id: String, parent: String? = nil, label: String) -> BookmarkNode {
        BookmarkNode(id: id, parentID: parent, position: 0, kind: .folder,
                     label: label, targetID: nil)
    }

    private func pageRef(_ id: String, parent: String?, target: String) -> BookmarkNode {
        BookmarkNode(id: id, parentID: parent, position: 0, kind: .pageRef,
                     label: nil, targetID: PageID(rawValue: target))
    }

    private func sourceRef(_ id: String, parent: String?, target: String) -> BookmarkNode {
        BookmarkNode(id: id, parentID: parent, position: 0, kind: .sourceRef,
                     label: nil, targetID: PageID(rawValue: target))
    }

    /// A trivial title resolver: maps node.targetID?.rawValue to the title,
    /// or node.label for folders.
    private static func resolver(_ node: BookmarkNode) -> String {
        switch node.kind {
        case .folder: return node.label ?? ""
        default: return node.targetID?.rawValue ?? ""
        }
    }

    // MARK: - Empty / no-match

    @Test func emptyQueryReturnsAllNodes() {
        let nodes = [
            folder("a", label: "Alpha"),
            folder("b", label: "Beta"),
        ]
        let result = BookmarksContainerView.filterNodes(nodes, query: "", resolveTitle: Self.resolver)
        #expect(result.count == 2)
    }

    @Test func whitespaceQueryReturnsAllNodes() {
        let nodes = [folder("a", label: "Alpha")]
        let result = BookmarksContainerView.filterNodes(nodes, query: "   ", resolveTitle: Self.resolver)
        #expect(result.count == 1)
    }

    @Test func noMatchReturnsEmpty() {
        let nodes = [folder("a", label: "Alpha")]
        let result = BookmarksContainerView.filterNodes(nodes, query: "xyz", resolveTitle: Self.resolver)
        #expect(result.isEmpty)
    }

    // MARK: - Folder label matching

    @Test func matchesFolderLabelCaseInsensitive() {
        let nodes = [folder("a", label: "Reading List")]
        let result = BookmarksContainerView.filterNodes(nodes, query: "reading", resolveTitle: Self.resolver)
        #expect(result.count == 1)
        #expect(result[0].id == "a")
    }

    // MARK: - Ref title matching

    @Test func matchesPageRefTitle() {
        let nodes = [
            folder("f", label: "Folder"),
            pageRef("p", parent: "f", target: "Mars Terraforming Guide"),
        ]
        let result = BookmarksContainerView.filterNodes(nodes, query: "mars", resolveTitle: Self.resolver)
        // Match + ancestor folder
        #expect(result.count == 2)
        #expect(result.contains { $0.id == "p" })
        #expect(result.contains { $0.id == "f" })
    }

    @Test func matchesSourceRefTitle() {
        let nodes = [
            sourceRef("s", parent: nil, target: "NASA Report.pdf"),
        ]
        let result = BookmarksContainerView.filterNodes(nodes, query: "nasa", resolveTitle: Self.resolver)
        #expect(result.count == 1)
        #expect(result[0].id == "s")
    }

    // MARK: - Ancestor expansion

    @Test func deeplyNestedMatchIncludesEntireAncestorChain() {
        let nodes = [
            folder("root", label: "Root"),
            folder("mid", parent: "root", label: "Mid"),
            folder("leaf", parent: "mid", label: "Leaf"),
            pageRef("p", parent: "leaf", target: "Hidden Gem"),
        ]
        let result = BookmarksContainerView.filterNodes(nodes, query: "hidden", resolveTitle: Self.resolver)
        // Matching node + 3 ancestor folders
        #expect(result.count == 4)
        #expect(Set(result.map(\.id)) == Set(["p", "leaf", "mid", "root"]))
    }

    @Test func nonMatchingSiblingIsExcluded() {
        let nodes = [
            folder("f", label: "Folder"),
            pageRef("p1", parent: "f", target: "Mars Guide"),
            pageRef("p2", parent: "f", target: "Venus Guide"),
        ]
        let result = BookmarksContainerView.filterNodes(nodes, query: "mars", resolveTitle: Self.resolver)
        // Folder + matching page, but NOT the non-matching sibling
        #expect(result.count == 2)
        #expect(Set(result.map(\.id)) == Set(["f", "p1"]))
    }

    // MARK: - Multiple matches

    @Test func multipleMatchesAllIncluded() {
        let nodes = [
            folder("f1", label: "Mars Research"),
            folder("f2", label: "Venus Research"),
            folder("f3", label: "Mercury Notes"),
        ]
        let result = BookmarksContainerView.filterNodes(nodes, query: "research", resolveTitle: Self.resolver)
        #expect(result.count == 2)
        #expect(Set(result.map(\.id)) == Set(["f1", "f2"]))
    }
}
#endif
