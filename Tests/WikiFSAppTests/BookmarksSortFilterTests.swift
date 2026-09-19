#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

// MARK: - Pure sorting (BookmarkSortOrder.sortedSiblings)

/// `sortedSiblings` per-order semantics (issue #241 AC.3): manual = position
/// ascending; nameAZ = localized case-insensitive title with position
/// tie-break; dateAdded / dateUpdated = newest first with position tie-break.
@Suite struct BookmarkSortedSiblingsTests {

    private func page(_ id: String, position: Int,
                      createdAt: Date = Date(timeIntervalSince1970: 0),
                      updatedAt: Date = Date(timeIntervalSince1970: 0)) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: nil, position: position,
            content: .page(PageID(rawValue: "target-\(id)")),
            createdAt: createdAt, updatedAt: updatedAt)
    }

    private func folder(_ id: String, _ label: String, position: Int) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: nil, position: position,
            content: .folder(label: label))
    }

    /// Resolves the display title the way the outline does: folder label,
    /// otherwise the (test-stable) raw target. A func (not a stored closure)
    /// so the static is Sendable.
    private static func resolver(_ node: BookmarkNode) -> String {
        node.label ?? node.targetRawValue ?? ""
    }

    @Test func manualKeepsPositionOrderFromShuffledInput() {
        let nodes = [page("n3", position: 2), page("n1", position: 0), page("n2", position: 1)]
        let result = BookmarkSortOrder.manual.sortedSiblings(nodes, resolveTitle: Self.resolver)
        #expect(result.map(\.position) == [0, 1, 2])
        #expect(result.map(\.id.rawValue) == ["n1", "n2", "n3"])
    }

    @Test func nameAZOrdersByTitleCaseInsensitively() {
        let nodes = [folder("f1", "Charlie", position: 0),
                     folder("f2", "alpha", position: 1),
                     folder("f3", "Bravo", position: 2)]
        let result = BookmarkSortOrder.nameAZ.sortedSiblings(nodes, resolveTitle: Self.resolver)
        #expect(result.map(\.id.rawValue) == ["f2", "f3", "f1"])
    }

    @Test func nameAZTieBreaksOnPosition() {
        let nodes = [folder("f1", "Same", position: 5), folder("f2", "Same", position: 1)]
        let result = BookmarkSortOrder.nameAZ.sortedSiblings(nodes, resolveTitle: Self.resolver)
        #expect(result.map(\.position) == [1, 5])
    }

    @Test func dateAddedNewestFirstWithEpochDefaultLast() {
        let nodes = [
            page("old", position: 0, createdAt: Date(timeIntervalSince1970: 100)),
            page("newest", position: 1, createdAt: Date(timeIntervalSince1970: 300)),
            page("mid", position: 2, createdAt: Date(timeIntervalSince1970: 200)),
            // Fixture default (epoch) — in-memory tests omit timestamps; these
            // sort last by design.
            page("epoch", position: 3),
        ]
        let result = BookmarkSortOrder.dateAdded.sortedSiblings(nodes, resolveTitle: Self.resolver)
        #expect(result.map(\.id.rawValue) == ["newest", "mid", "old", "epoch"])
    }

    @Test func dateAddedTieBreaksOnPosition() {
        let stamp = Date(timeIntervalSince1970: 500)
        let nodes = [page("b", position: 9, createdAt: stamp), page("a", position: 2, createdAt: stamp)]
        let result = BookmarkSortOrder.dateAdded.sortedSiblings(nodes, resolveTitle: Self.resolver)
        #expect(result.map(\.position) == [2, 9])
    }

    @Test func dateUpdatedNewestFirst() {
        let nodes = [
            page("old", position: 0, updatedAt: Date(timeIntervalSince1970: 10)),
            page("newest", position: 1, updatedAt: Date(timeIntervalSince1970: 30)),
            page("mid", position: 2, updatedAt: Date(timeIntervalSince1970: 20)),
        ]
        let result = BookmarkSortOrder.dateUpdated.sortedSiblings(nodes, resolveTitle: Self.resolver)
        #expect(result.map(\.id.rawValue) == ["newest", "mid", "old"])
    }
}

// MARK: - Pure filtering (kind filter + search composition)

/// Kind-filter semantics (issue #241 AC.1/AC.2/AC.8): filtering by kind keeps
/// exactly the matching refs plus their ancestor folders; `.all` with an
/// empty query returns the input unchanged; query and kind compose
/// conjunctively.
@Suite struct BookmarkKindFilterTests {

    private func folder(_ id: String, parent: String? = nil, label: String) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: parent.map(BookmarkID.init(rawValue:)),
            position: 0, content: .folder(label: label))
    }

    private func pageRef(_ id: String, parent: String?, target: String) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: parent.map(BookmarkID.init(rawValue:)),
            position: 0, content: .page(PageID(rawValue: target)))
    }

    private func sourceRef(_ id: String, parent: String?, target: String) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: parent.map(BookmarkID.init(rawValue:)),
            position: 0, content: .source(SourceID(rawValue: target)))
    }

    private func chatRef(_ id: String, parent: String?, target: String) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: parent.map(BookmarkID.init(rawValue:)),
            position: 0, content: .chat(ChatID(rawValue: target)))
    }

    private static func resolver(_ node: BookmarkNode) -> String {
        switch node.kind {
        case .folder: return node.label ?? ""
        default: return node.targetRawValue ?? ""
        }
    }

    /// One folder (with one ref of each kind inside) plus a childless folder —
    /// every kind test filters the same fixture.
    private func mixedFixture() -> [BookmarkNode] {
        [
            folder("root", label: "Root"),
            folder("empty", label: "Empty Childless"),
            folder("mid", parent: "root", label: "Mid"),
            pageRef("p", parent: "mid", target: "Mars Guide"),
            sourceRef("s", parent: "mid", target: "NASA Report"),
            chatRef("c", parent: "mid", target: "Planning Chat"),
        ]
    }

    private func ids(_ result: [BookmarkNode]) -> Set<String> {
        Set(result.map { $0.id.rawValue })
    }

    @Test func pagesFilterKeepsPageRefsAndAncestorFolders() {
        let result = BookmarksContainerView.filterNodes(
            mixedFixture(), query: "", kindFilter: .pages, resolveTitle: Self.resolver)
        #expect(ids(result) == ["root", "mid", "p"])
    }

    @Test func sourcesFilterKeepsSourceRefsAndAncestorFolders() {
        let result = BookmarksContainerView.filterNodes(
            mixedFixture(), query: "", kindFilter: .sources, resolveTitle: Self.resolver)
        #expect(ids(result) == ["root", "mid", "s"])
    }

    @Test func chatsFilterKeepsChatRefsAndAncestorFolders() {
        let result = BookmarksContainerView.filterNodes(
            mixedFixture(), query: "", kindFilter: .chats, resolveTitle: Self.resolver)
        #expect(ids(result) == ["root", "mid", "c"])
    }

    @Test func foldersFilterKeepsFolderChainDropsLeaves() {
        let result = BookmarksContainerView.filterNodes(
            mixedFixture(), query: "", kindFilter: .folders, resolveTitle: Self.resolver)
        // "Empty Childless" is a folder too — every folder stays.
        #expect(ids(result) == ["root", "mid", "empty"])
    }

    @Test func allFilterReturnsInputUnchanged() {
        let nodes = mixedFixture()
        let result = BookmarksContainerView.filterNodes(
            nodes, query: "", kindFilter: .all, resolveTitle: Self.resolver)
        #expect(result == nodes)
    }

    @Test func queryAndKindFilterComposeConjunctively() {
        let nodes = [
            folder("f", label: "Folder"),
            pageRef("p1", parent: "f", target: "Mars Alpha"),
            pageRef("p2", parent: "f", target: "Venus Beta"),
            sourceRef("s1", parent: "f", target: "Mars Source"),
        ]
        // "Mars" matches the source ref too, but the kind filter excludes it.
        let result = BookmarksContainerView.filterNodes(
            nodes, query: "mars", kindFilter: .pages, resolveTitle: Self.resolver)
        #expect(ids(result) == ["f", "p1"])
    }

    @Test func emptyQueryAllFilterReturnsInputWrapperCompatibility() {
        // The two-argument call site used by BookmarksSearchTests must keep
        // compiling and returning the input unchanged (default `kindFilter`).
        let nodes = [folder("a", label: "Alpha"), pageRef("p", parent: "a", target: "Mars")]
        let result = BookmarksContainerView.filterNodes(nodes, query: "", resolveTitle: Self.resolver)
        #expect(result == nodes)
    }

    @Test func visibleNodesPurePredicateCore() {
        let nodes = mixedFixture()
        let result = BookmarksContainerView.visibleNodes(nodes) { $0.kind == .sourceRef }
        #expect(ids(result) == ["root", "mid", "s"])
    }
}

// MARK: - Drag gate matrix (pure)

/// `isReorderAllowed` matrix (issue #241 AC.7): manual allows everything;
/// every non-manual order allows only the folder drop-ON destination.
@Suite struct BookmarkReorderGateTests {

    private let nonManualOrders: [BookmarkSortOrder] = [.nameAZ, .dateAdded, .dateUpdated]
    private let dropOn = NSOutlineViewDropOnItemIndex

    @Test func manualAllowsEverything() {
        for destination in [true, false] {
            for index in [dropOn, 0, 1, 7] {
                #expect(BookmarksOutlineViewController.isReorderAllowed(
                    sortOrder: .manual,
                    isFolderDestination: destination,
                    dropIndex: index))
            }
        }
    }

    @Test func nonManualAllowsOnlyFolderDropOn() {
        for order in nonManualOrders {
            #expect(BookmarksOutlineViewController.isReorderAllowed(
                sortOrder: order, isFolderDestination: true, dropIndex: dropOn))
            // Folder with a between-sibling insertion index: refused.
            #expect(!BookmarksOutlineViewController.isReorderAllowed(
                sortOrder: order, isFolderDestination: true, dropIndex: 0))
            #expect(!BookmarksOutlineViewController.isReorderAllowed(
                sortOrder: order, isFolderDestination: true, dropIndex: 3))
            // Leaf destinations: refused under every non-manual sort.
            #expect(!BookmarksOutlineViewController.isReorderAllowed(
                sortOrder: order, isFolderDestination: false, dropIndex: dropOn))
            #expect(!BookmarksOutlineViewController.isReorderAllowed(
                sortOrder: order, isFolderDestination: false, dropIndex: 0))
        }
    }
}

// MARK: - Outline ordering (direct VC)

/// The outline renders siblings in the selected order (issue #241 AC.4/AC.5),
/// and `needsReload(nodes:sortOrder:)` detects a sort change with identical
/// nodes.
@MainActor
@Suite struct BookmarksOutlineSortOrderTests {

    private func makeVC(nodes: [BookmarkNode]) -> BookmarksOutlineViewController {
        let vc = BookmarksOutlineViewController()
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

    private func page(_ id: String, position: Int,
                      createdAt: Date = Date(timeIntervalSince1970: 0)) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: nil, position: position,
            content: .page(PageID(rawValue: "target-\(id)")), createdAt: createdAt)
    }

    private func folder(_ id: String, _ label: String, position: Int) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: nil, position: position,
            content: .folder(label: label))
    }

    private func rootItems(_ vc: BookmarksOutlineViewController) -> [BookmarkNode] {
        guard let outline = vc.outlineView else { return [] }
        return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? BookmarkNode }
    }

    @Test func defaultSortOrderIsManual() {
        let vc = makeVC(nodes: [page("n1", position: 0)])
        #expect(vc.sortOrder == .manual)
    }

    @Test func manualRendersRootRowsByPosition() {
        let nodes = [page("n3", position: 2), page("n1", position: 0), page("n2", position: 1)]
        let vc = makeVC(nodes: nodes)
        #expect(rootItems(vc).map { $0.id.rawValue } == ["n1", "n2", "n3"])
    }

    @Test func nameAZRendersRowsAlphabetically() {
        // Folder labels resolve with a nil store (no summaries needed).
        let nodes = [folder("f1", "Charlie", position: 0),
                     folder("f2", "alpha", position: 1),
                     folder("f3", "Bravo", position: 2)]
        let vc = makeVC(nodes: nodes)
        vc.sortOrder = .nameAZ
        vc.reloadData(from: nodes)
        #expect(rootItems(vc).map { $0.id.rawValue } == ["f2", "f3", "f1"])
    }

    @Test func dateAddedRendersNewestFirst() {
        let nodes = [
            page("old", position: 0, createdAt: Date(timeIntervalSince1970: 100)),
            page("newest", position: 1, createdAt: Date(timeIntervalSince1970: 300)),
            page("mid", position: 2, createdAt: Date(timeIntervalSince1970: 200)),
            page("epoch", position: 3),
        ]
        let vc = makeVC(nodes: nodes)
        vc.sortOrder = .dateAdded
        vc.reloadData(from: nodes)
        #expect(rootItems(vc).map { $0.id.rawValue } == ["newest", "mid", "old", "epoch"])
    }

    @Test func needsReloadDetectsSortChangeWithIdenticalNodes() {
        let nodes = [page("n1", position: 0), page("n2", position: 1)]
        let vc = makeVC(nodes: nodes)
        #expect(vc.needsReload(nodes: nodes, sortOrder: .manual) == false)
        #expect(vc.needsReload(nodes: nodes, sortOrder: .nameAZ) == true)
        #expect(vc.needsReload(nodes: nodes, sortOrder: .dateAdded) == true)
    }

    @Test func needsReloadDetectsNodeChangeUnderManual() {
        let nodes = [page("n1", position: 0), page("n2", position: 1)]
        let vc = makeVC(nodes: nodes)
        let moved = [page("n2", position: 0), page("n1", position: 1)]
        #expect(vc.needsReload(nodes: moved, sortOrder: .manual) == true)
    }
}

// MARK: - Drag-gate wiring (validateDrop / acceptDrop)

/// The sort gate wired into the real drag-and-drop entry points (issue #241
/// AC.7): under a non-manual sort, leaf between-sibling insertions are
/// refused while folder drop-on and root moves stay allowed; wiki-link copy
/// drops are unaffected.
@MainActor
@Suite struct BookmarksDragGateWiringTests {

    /// The private pasteboard type marking an intra-outline drag.
    private static let bookmarkNodeType =
        NSPasteboard.PasteboardType("com.selfdrivingwiki.bookmark-node-id")

    /// Minimal `NSDraggingInfo` stand-in: `validateDrop` only reads
    /// `draggingSourceOperationMask` and `draggingPasteboard`. The remaining
    /// members satisfy the (large) `@objc` protocol surface on this SDK.
    private final class DraggingInfoStub: NSObject, NSDraggingInfo {
        let pasteboard: NSPasteboard
        let mask: NSDragOperation

        init(pasteboard: NSPasteboard, mask: NSDragOperation) {
            self.pasteboard = pasteboard
            self.mask = mask
            super.init()
        }

        var draggingLocation: NSPoint { .zero }
        var draggingSourceOperationMask: NSDragOperation { mask }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { nil }
        var numberOfValidItemsForDrop: Int = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .standard }
        func resetSpringLoading() {}
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions,
            for view: NSView?,
            classes: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        // Legacy drag-visual members still required by the protocol.
        var draggedImage: NSImage? { nil }
        var draggedImageLocation: NSPoint { .zero }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingFormation: NSDraggingFormation = .none
        var draggingSequenceNumber: Int { 0 }
        var animatesToDestination: Bool = false
    }

    private func makeVC(nodes: [BookmarkNode], sortOrder: BookmarkSortOrder) -> BookmarksOutlineViewController {
        let vc = BookmarksOutlineViewController()
        vc.fileProvider = nil
        vc.callbacks = BookmarksCallbacks(
            onOpen: { _ in }, onOpenBackground: { _ in },
            onGoToOriginal: { _ in },
            onEdit: { _ in }, onDelete: { _ in },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )
        vc.loadView()
        vc.sortOrder = sortOrder
        vc.reloadData(from: nodes)
        return vc
    }

    private func leaf(_ id: String, position: Int) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: nil, position: position,
            content: .page(PageID(rawValue: "target-\(id)")))
    }

    private func folder(_ id: String, _ label: String, position: Int) -> BookmarkNode {
        BookmarkNode(
            id: BookmarkID(rawValue: id), parentID: nil, position: position,
            content: .folder(label: label))
    }

    /// A pasteboard carrying the intra-outline bookmark-node-id type, as the
    /// outline's own `pasteboardWriterForItem` writes it.
    private func internalDragPasteboard(nodeIDs: [String]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("sortfilter-\(UUID().uuidString)"))
        pb.clearContents()
        let items: [NSPasteboardItem] = nodeIDs.map { id in
            let item = NSPasteboardItem()
            item.setString(id, forType: Self.bookmarkNodeType)
            return item
        }
        pb.writeObjects(items)
        return pb
    }

    /// A pasteboard carrying a `wiki://` link, as a WebKit link drag does.
    private func wikiLinkPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("wikilink-\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("wiki://page?title=Alpha", forType: .init("public.url"))
        pb.writeObjects([item])
        return pb
    }

    private func validate(_ vc: BookmarksOutlineViewController,
                          pb: NSPasteboard,
                          item: Any?,
                          index: Int) -> NSDragOperation {
        let info = DraggingInfoStub(pasteboard: pb, mask: [.move, .copy])
        return vc.outlineView(vc.outlineView!, validateDrop: info,
                              proposedItem: item, proposedChildIndex: index)
    }

    @Test func nameAZRefusesLeafBetweenSiblingInsert() {
        let nodes = [leaf("n1", position: 0), leaf("n2", position: 1), leaf("n3", position: 2)]
        let vc = makeVC(nodes: nodes, sortOrder: .nameAZ)
        let op = validate(vc, pb: internalDragPasteboard(nodeIDs: ["n1"]),
                          item: nodes[1], index: 1)
        #expect(op == [])
    }

    @Test func nameAZRefusesLeafDropOn() {
        let nodes = [leaf("n1", position: 0), leaf("n2", position: 1)]
        let vc = makeVC(nodes: nodes, sortOrder: .nameAZ)
        let op = validate(vc, pb: internalDragPasteboard(nodeIDs: ["n1"]),
                          item: nodes[1], index: NSOutlineViewDropOnItemIndex)
        #expect(op == [])
    }

    @Test func nameAZAllowsFolderDropOn() {
        let nodes = [folder("f1", "Folder", position: 0), leaf("n1", position: 1)]
        let vc = makeVC(nodes: nodes, sortOrder: .nameAZ)
        let op = validate(vc, pb: internalDragPasteboard(nodeIDs: ["n1"]),
                          item: nodes[0], index: NSOutlineViewDropOnItemIndex)
        #expect(op == .move)
    }

    @Test func nameAZRefusesFolderBetweenSiblingInsert() {
        let nodes = [folder("f1", "Folder", position: 0), leaf("n1", position: 1)]
        let vc = makeVC(nodes: nodes, sortOrder: .nameAZ)
        let op = validate(vc, pb: internalDragPasteboard(nodeIDs: ["n1"]),
                          item: nodes[0], index: 0)
        #expect(op == [])
    }

    @Test func nameAZAllowsRootMove() {
        let nodes = [leaf("n1", position: 0), leaf("n2", position: 1)]
        let vc = makeVC(nodes: nodes, sortOrder: .nameAZ)
        let op = validate(vc, pb: internalDragPasteboard(nodeIDs: ["n1"]),
                          item: nil, index: 0)
        #expect(op == .move)
    }

    @Test func manualStillAllowsLeafInsert() {
        let nodes = [leaf("n1", position: 0), leaf("n2", position: 1)]
        let vc = makeVC(nodes: nodes, sortOrder: .manual)
        let op = validate(vc, pb: internalDragPasteboard(nodeIDs: ["n1"]),
                          item: nodes[1], index: 0)
        #expect(op == .move)
    }

    @Test func wikiLinkCopyUnaffectedBySort() {
        let nodes = [folder("f1", "Folder", position: 0), leaf("n1", position: 1)]
        let vc = makeVC(nodes: nodes, sortOrder: .nameAZ)
        let pb = wikiLinkPasteboard()
        // Root, folder, and leaf destinations all stay `.copy`.
        #expect(validate(vc, pb: pb, item: nil, index: 0) == .copy)
        #expect(validate(vc, pb: pb, item: nodes[0], index: NSOutlineViewDropOnItemIndex) == .copy)
        #expect(validate(vc, pb: pb, item: nodes[1], index: 0) == .copy)
    }
}

// MARK: - Store-backed rename re-sort (AC.6)

/// Renaming a page changes only `store.summaries`; under `.nameAZ` the
/// outline's signature must still invalidate so the next reload re-sorts.
@MainActor
@Suite struct BookmarksSortRenameStoreTests {

    private func tempModel() throws -> (model: WikiStoreModel, store: GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-sortfilter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    private func pageTitle(for node: BookmarkNode, in model: WikiStoreModel) -> String {
        switch node.content {
        case .folder(let label): return label
        case .page(let id): return model.summaries.first { $0.id == id }?.title ?? "?"
        case .source, .chat: return "?"
        }
    }

    private func rootItems(_ vc: BookmarksOutlineViewController) -> [BookmarkNode] {
        guard let outline = vc.outlineView else { return [] }
        return (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? BookmarkNode }
    }

    @Test func pageRenameUnderNameAZInvalidatesAndReSorts() throws {
        let (model, store) = try tempModel()
        let beta = try store.createPage(title: "Beta")
        let alpha = try store.createPage(title: "Alpha")
        model.reloadFromStore()
        model.addPageRef(parentID: nil, pageID: beta.id, position: 0)
        model.addPageRef(parentID: nil, pageID: alpha.id, position: 1)
        // addPageRef refreshes the model via the async event bus — force the
        // reload synchronously so bookmarkNodes is populated for the outline.
        model.reloadFromStore()

        let vc = BookmarksOutlineViewController()
        vc.fileProvider = nil
        vc.callbacks = BookmarksCallbacks(
            onOpen: { _ in }, onOpenBackground: { _ in },
            onGoToOriginal: { _ in },
            onEdit: { _ in }, onDelete: { _ in },
            onAddPage: { _ in }, onAddSource: { _ in },
            onNewFolder: {}, onNewSubfolder: { _ in }
        )
        vc.loadView()
        vc.store = model
        vc.sortOrder = .nameAZ

        let nodes = model.bookmarkNodes
        vc.reloadData(from: nodes)
        // Position order was Beta(0), Alpha(1); name order is Alpha first.
        let before = rootItems(vc).map { pageTitle(for: $0, in: model) }
        #expect(before == ["Alpha", "Beta"])

        // Rename: node fields unchanged, only summaries moves. The rename
        // also refreshes the model via the async bus — force it so the
        // title index below sees the new title.
        model.rename(alpha.id, to: "Zeta")
        model.reloadFromStore()
        #expect(vc.needsReload(nodes: nodes, sortOrder: .nameAZ) == true)

        vc.reloadData(from: nodes)
        let after = rootItems(vc).map { pageTitle(for: $0, in: model) }
        #expect(after == ["Beta", "Zeta"])
    }
}

// MARK: - Hosted header UI (AC.9)

/// The Bookmarks header's hosted checks: the "Show" and "Sort by" pickers
/// mount when at least one bookmark exists, hide (with the search bar) when
/// the store has none, and the default manual outline renders position order.
///
/// The picker menu-item titles, "Name A–Z" selection reorder, the search /
/// kind-filter empty state, and the "No matching bookmarks" overlay render
/// are NOT driven here: SwiftUI populates an NSPopUpButton's menu lazily and
/// every route into a menu-tracking session wedges the `swift test` CLI host
/// (the nested run loop never releases without a real user event), and
/// programmatic text edits never reach the SwiftUI search state. Per the
/// plan's flagged contingency, those render checks fall to a manual operator
/// check — the underlying state, ordering, and filtering behavior stays
/// covered by the AC.1–AC.8 suites.
@MainActor
@Suite struct BookmarksHeaderHostedTests {

    /// An `NSHostingController` in a `swift test` CLI has no host app — give
    /// AppKit one to lay out into (same pattern as `PageContextMenuHostedTests`).
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func tempModel() throws -> (model: WikiStoreModel, store: GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-header-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    private func makeContainer(model: WikiStoreModel) -> NSHostingController<BookmarksContainerView> {
        NSHostingController(
            rootView: BookmarksContainerView(
                store: model,
                fileProvider: FileProviderFacade(),
                onShowPicker: { _ in },
                onEdit: { _ in },
                onNewFolder: {}))
    }

    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for sub in view.subviews { found.append(contentsOf: findAll(type, in: sub)) }
        return found
    }

    private func hasText(_ view: NSView, _ needle: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue.contains(needle) { return true }
        return view.subviews.contains { hasText($0, needle) }
    }

    @Test func headerPickersMountWhenBookmarksExist() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let (model, store) = try tempModel()
        let beta = try store.createPage(title: "Beta")
        let alpha = try store.createPage(title: "Alpha")
        model.reloadFromStore()
        model.addPageRef(parentID: nil, pageID: beta.id, position: 0)
        model.addPageRef(parentID: nil, pageID: alpha.id, position: 1)
        // addPageRef refreshes the model via the async event bus — force the
        // reload synchronously so the header's `!bookmarkNodes.isEmpty` gate
        // sees the nodes at mount.
        model.reloadFromStore()

        let hosting = makeContainer(model: model)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 320, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Wait for both pickers to mount.
        var popups: [NSPopUpButton] = []
        for _ in 0..<200 {
            popups = findAll(NSPopUpButton.self, in: hosting.view)
            if popups.count >= 2 { break }
            await Task.yield()
        }
        #expect(popups.count == 2, "the Show and Sort by pickers never mounted")

        // Default (manual) outline order: position — Beta, then Alpha.
        func outlineTitles() -> [String] {
            guard let outline = findAll(NSOutlineView.self, in: hosting.view).first else { return [] }
            let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? BookmarkNode }
            return nodes.map { node in
                switch node.content {
                case .page(let id):
                    return model.summaries.first { $0.id == id }?.title ?? "?"
                default:
                    return "?"
                }
            }
        }
        #expect(outlineTitles() == ["Beta", "Alpha"])
    }

    @Test func headerControlsAbsentWhenNoBookmarks() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let (model, _) = try tempModel()

        let hosting = makeContainer(model: model)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 320, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Give layout a few turns, then confirm no picker rows exist.
        for _ in 0..<20 { await Task.yield() }
        #expect(findAll(NSPopUpButton.self, in: hosting.view).isEmpty)
    }
}
#endif
