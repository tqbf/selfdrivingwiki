#if os(macOS)
import Testing
import Foundation
import AppKit
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for the bookmarks outline's multi-select context menu.
///
/// These drive `BookmarksOutlineViewController` directly: populate the
/// outline, simulate row selection, call the delegate's `menuFor`, and
/// inspect the resulting `NSMenu`. This catches the three things that
/// broke before this fix:
/// - Batch titles ("Open 3", "Delete 3") for multi-selection
/// - Effective selection (right-click inside vs outside the selection)
/// - Single-item-only items (Edit, Add Page/Source) hidden for batches
@MainActor
struct BookmarksMultiSelectMenuTests {

    // MARK: - Helpers

    private func makeVC(nodes: [BookmarkNode]) -> BookmarksOutlineViewController {
        let vc = BookmarksOutlineViewController()
        // No fileProvider → "Open With" submenu is skipped (simplifies tests).
        vc.fileProvider = nil
        vc.callbacks = BookmarksCallbacks(
            onOpen: { _ in }, onOpenBackground: { _ in },
            onGoToOriginal: { _ in },
            onEdit: { _ in }, onDelete: { _ in },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )
        vc.loadView()
        vc.reloadData(from: nodes)
        return vc
    }

    private func leaf(_ id: String, kind: BookmarkNodeKind = .pageRef,
                      targetID: String = "target") -> BookmarkNode {
        BookmarkNode(id: id, parentID: nil, position: 0, kind: kind,
                     label: nil, targetID: PageID(rawValue: targetID))
    }

    private func folder(_ id: String) -> BookmarkNode {
        BookmarkNode(id: id, parentID: nil, position: 0, kind: .folder,
                     label: "Folder \(id)", targetID: nil)
    }

    /// Calls `menuFor` on the VC and returns the non-separator item titles.
    private func menuTitles(_ vc: BookmarksOutlineViewController,
                            clicked: BookmarkNode) -> [String] {
        guard let outline = vc.outlineView else { return [] }
        let buildMenu: (NSOutlineView, Any) -> NSMenu? = vc.outlineView(_:menuFor:)
        guard let menu = buildMenu(outline, clicked) else { return [] }
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    // MARK: - Single-item menu

    @Test func singleLeafShowsStandardTitles() {
        let nodes = [leaf("n1")]
        let vc = makeVC(nodes: nodes)
        let titles = menuTitles(vc, clicked: nodes[0])

        #expect(titles.contains("Open"))
        #expect(titles.contains("Open in Background"))
        #expect(titles.contains("Edit…"))
        #expect(titles.contains("Delete"))
        // No count suffixes.
        #expect(!titles.contains { $0.contains(where: \.isNumber) })
    }

    @Test func singleFolderShowsFolderActions() {
        let nodes = [folder("f1")]
        let vc = makeVC(nodes: nodes)
        let titles = menuTitles(vc, clicked: nodes[0])

        // Folders have no Open / Open in Background.
        #expect(!titles.contains("Open"))
        #expect(!titles.contains("Open in Background"))
        #expect(titles.contains("Edit…"))
        #expect(titles.contains("Add Page…"))
        #expect(titles.contains("Add Source…"))
        #expect(titles.contains("Delete"))
    }

    // MARK: - Multi-select leaf menu

    @Test func multiLeafShowsBatchTitles() {
        let nodes = [leaf("n1"), leaf("n2"), leaf("n3")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        // Select all three rows.
        outline.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)

        // Right-click inside the selection.
        let titles = menuTitles(vc, clicked: nodes[0])

        #expect(titles.contains("Open 3"))
        #expect(titles.contains("Open 3 in Background"))
        #expect(titles.contains("Delete 3"))
        // Single-item-only items are hidden.
        #expect(!titles.contains("Edit…"))
    }

    @Test func multiLeafWithTwoShowsCount2() {
        let nodes = [leaf("n1"), leaf("n2")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        outline.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        let titles = menuTitles(vc, clicked: nodes[0])

        #expect(titles.contains("Open 2"))
        #expect(titles.contains("Delete 2"))
    }

    // MARK: - Effective selection

    @Test func rightClickOutsideSelectionActsOnClickedRowOnly() {
        let nodes = [leaf("n1"), leaf("n2"), leaf("n3")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        // Select rows 0 and 1 only.
        outline.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        // Right-click on row 2 (outside the selection).
        let titles = menuTitles(vc, clicked: nodes[2])

        // Should act on just the clicked row — no count suffix.
        #expect(titles.contains("Open"))
        #expect(!titles.contains("Open 2"))
        #expect(titles.contains("Delete"))
        #expect(!titles.contains("Delete 2"))
    }

    @Test func rightClickInsideSelectionActsOnAllSelected() {
        let nodes = [leaf("n1"), leaf("n2"), leaf("n3"), leaf("n4")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        // Select rows 0, 2, 3 (non-contiguous: skip row 1).
        outline.selectRowIndexes(IndexSet([0, 2, 3]), byExtendingSelection: false)

        // Right-click on row 2 (inside selection).
        let titles = menuTitles(vc, clicked: nodes[2])

        #expect(titles.contains("Open 3"))
        #expect(titles.contains("Delete 3"))
    }

    // MARK: - Mixed folder + leaf selection

    @Test func mixedFolderAndLeafShowsOpen1Delete2() {
        let nodes = [leaf("n1"), folder("f1")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        outline.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        let titles = menuTitles(vc, clicked: nodes[0])

        // Only 1 openable leaf → "Open 1".
        #expect(titles.contains("Open 1"))
        #expect(titles.contains("Open 1 in Background"))
        // 2 effective nodes → "Delete 2".
        #expect(titles.contains("Delete 2"))
    }

    @Test func folderOnlySelectionShowsNoOpenItems() {
        let nodes = [folder("f1"), folder("f2")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        outline.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        let titles = menuTitles(vc, clicked: nodes[0])

        // No openable leaves → no Open items at all.
        #expect(!titles.contains { $0.hasPrefix("Open") })
        // Still has Delete for the 2 folders.
        #expect(titles.contains("Delete 2"))
    }

    // MARK: - Callback invocation

    @Test func deleteCallbackReceivesAllEffectiveNodeIDs() {
        let nodes = [leaf("n1"), leaf("n2"), leaf("n3")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        var deletedIDs: [String] = []
        vc.callbacks = BookmarksCallbacks(
            onOpen: { _ in }, onOpenBackground: { _ in },
            onGoToOriginal: { _ in },
            onEdit: { _ in },
            onDelete: { ids in deletedIDs = ids },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )

        outline.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)

        let buildMenu: (NSOutlineView, Any) -> NSMenu? = vc.outlineView(_:menuFor:)
        let menu = buildMenu(outline, nodes[0])!
        let deleteItem = menu.items.first { $0.title == "Delete 3" }!

        // Simulate the menu action.
        _ = vc.perform(deleteItem.action, with: deleteItem)

        #expect(deletedIDs.count == 3)
        #expect(Set(deletedIDs) == Set(["n1", "n2", "n3"]))
    }

    @Test func openCallbackReceivesOnlyOpenableSelections() {
        let nodes = [leaf("n1"), folder("f1"), leaf("n2", kind: .sourceRef)]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        var openedSelections: [WikiSelection] = []
        vc.callbacks = BookmarksCallbacks(
            onOpen: { sels in openedSelections = sels },
            onOpenBackground: { _ in },
            onGoToOriginal: { _ in },
            onEdit: { _ in }, onDelete: { _ in },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )

        outline.selectRowIndexes(IndexSet(integersIn: 0..<3), byExtendingSelection: false)

        let buildMenu: (NSOutlineView, Any) -> NSMenu? = vc.outlineView(_:menuFor:)
        let menu = buildMenu(outline, nodes[0])!
        let openItem = menu.items.first { $0.title == "Open 2" }!

        _ = vc.perform(openItem.action, with: openItem)

        // The folder is skipped — only the pageRef and sourceRef are opened.
        #expect(openedSelections.count == 2)
        if openedSelections.count == 2 {
            #expect(openedSelections.contains(.page(PageID(rawValue: "target"))))
            #expect(openedSelections.contains(.source(PageID(rawValue: "target"))))
        }
    }

    // MARK: - "Go to Original" action

    @Test func goToOriginalShownForSingleLeaf() {
        let nodes = [leaf("n1")]
        let vc = makeVC(nodes: nodes)
        let titles = menuTitles(vc, clicked: nodes[0])

        #expect(titles.contains("Go to Original"))
    }

    @Test func goToOriginalHiddenForFolder() {
        let nodes = [folder("f1")]
        let vc = makeVC(nodes: nodes)
        let titles = menuTitles(vc, clicked: nodes[0])

        #expect(!titles.contains("Go to Original"))
    }

    @Test func goToOriginalHiddenForBatch() {
        let nodes = [leaf("n1"), leaf("n2")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        outline.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)

        let titles = menuTitles(vc, clicked: nodes[0])

        // Batches are ambiguous about which item to reveal.
        #expect(!titles.contains("Go to Original"))
    }

    @Test func goToOriginalRevealsPageTarget() {
        let nodes = [leaf("n1", kind: .pageRef, targetID: "page-1")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        var revealed: WikiSelection?
        vc.callbacks = BookmarksCallbacks(
            onOpen: { _ in }, onOpenBackground: { _ in },
            onGoToOriginal: { sel in revealed = sel },
            onEdit: { _ in }, onDelete: { _ in },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )

        let buildMenu: (NSOutlineView, Any) -> NSMenu? = vc.outlineView(_:menuFor:)
        let menu = buildMenu(outline, nodes[0])!
        let item = menu.items.first { $0.title == "Go to Original" }!

        _ = vc.perform(item.action, with: item)

        #expect(revealed == .page(PageID(rawValue: "page-1")))
    }

    @Test func goToOriginalRevealsChatTarget() {
        let nodes = [leaf("n1", kind: .chatRef, targetID: "chat-1")]
        let vc = makeVC(nodes: nodes)
        let outline = vc.outlineView!

        var revealed: WikiSelection?
        vc.callbacks = BookmarksCallbacks(
            onOpen: { _ in }, onOpenBackground: { _ in },
            onGoToOriginal: { sel in revealed = sel },
            onEdit: { _ in }, onDelete: { _ in },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )

        let buildMenu: (NSOutlineView, Any) -> NSMenu? = vc.outlineView(_:menuFor:)
        let menu = buildMenu(outline, nodes[0])!
        let item = menu.items.first { $0.title == "Go to Original" }!

        _ = vc.perform(item.action, with: item)

        #expect(revealed == .chat(PageID(rawValue: "chat-1")))
    }
}
#endif
