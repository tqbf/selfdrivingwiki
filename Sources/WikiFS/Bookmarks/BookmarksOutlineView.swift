import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WikiFSCore

// MARK: - SwiftUI bridge

/// SwiftUI wrapper for the bookmarks `NSOutlineView`. Replaces the slow
/// SwiftUI `List`/`OutlineGroup` which has severe selection-update latency
/// on macOS (see plans/bookmark-drag-drop-performance.md).
struct BookmarksOutlineView: NSViewControllerRepresentable {
    let store: WikiStoreModel
    /// The live bookmark-node snapshot. Passed explicitly (rather than read
    /// inside `updateNSViewController`) so that the **parent** view
    /// (`BookmarksContainerView`) accesses `store.bookmarkNodes` during its
    /// `body` evaluation — establishing the `@Observable` dependency that
    /// triggers a re-render when bookmarks change. Without this, mutations from
    /// the omnibox "+", context menus, etc. update the database but the outline
    /// never refreshes (no SwiftUI state change to force `updateNSViewController`).
    let nodes: [BookmarkNode]
    /// When true, all folders are force-expanded (used during search so hits
    /// inside collapsed folders are immediately visible).
    var forceExpandAll: Bool = false
    let fileProvider: FileProviderFacade
    // All callbacks are main-actor-isolated: they touch the @MainActor
    // WikiStoreModel or present UI. @Sendable so they can be captured by the
    // NSViewControllerRepresentable bridge without losing isolation.
    var onOpen: (@MainActor @Sendable ([WikiSelection]) -> Void)
    var onOpenBackground: (@MainActor @Sendable ([WikiSelection]) -> Void)
    var onGoToOriginal: (@MainActor @Sendable (WikiSelection) -> Void)
    var onEdit: (@MainActor @Sendable (String) -> Void)
    var onDelete: (@MainActor @Sendable ([String]) -> Void)
    var onAddPage: (@MainActor @Sendable (String?) -> Void)
    var onAddSource: (@MainActor @Sendable (String?) -> Void)
    var onNewFolder: (@MainActor @Sendable () -> Void)
    var onNewSubfolder: (@MainActor @Sendable (String) -> Void)

    func makeNSViewController(context: Context) -> BookmarksOutlineViewController {
        let vc = BookmarksOutlineViewController()
        vc.store = store
        vc.fileProvider = fileProvider
        vc.callbacks = .init(
            onOpen: onOpen, onOpenBackground: onOpenBackground,
            onGoToOriginal: onGoToOriginal,
            onEdit: onEdit, onDelete: onDelete,
            onAddPage: onAddPage, onAddSource: onAddSource,
            onNewFolder: onNewFolder, onNewSubfolder: onNewSubfolder
        )
        // Don't call reloadData here — loadView hasn't run yet.
        // Initial data load happens in viewDidLoad.
        return vc
    }

    func updateNSViewController(_ vc: BookmarksOutlineViewController, context: Context) {
        vc.store = store
        vc.fileProvider = fileProvider
        vc.callbacks = .init(
            onOpen: onOpen, onOpenBackground: onOpenBackground,
            onGoToOriginal: onGoToOriginal,
            onEdit: onEdit, onDelete: onDelete,
            onAddPage: onAddPage, onAddSource: onAddSource,
            onNewFolder: onNewFolder, onNewSubfolder: onNewSubfolder
        )
        let needs = vc.needsReload(nodes: nodes) || vc.forceExpandAll != forceExpandAll
        vc.forceExpandAll = forceExpandAll
        DebugLog.tabs("BookmarksOutlineView.updateNSVC: nodes=\(nodes.count) needsReload=\(needs)")
        if needs {
            vc.reloadData(from: nodes)
        }
    }
}

// MARK: - Callbacks

struct BookmarksCallbacks {
    var onOpen: (@MainActor @Sendable ([WikiSelection]) -> Void)
    var onOpenBackground: (@MainActor @Sendable ([WikiSelection]) -> Void)
    var onGoToOriginal: (@MainActor @Sendable (WikiSelection) -> Void)
    var onEdit: (@MainActor @Sendable (String) -> Void)
    var onDelete: (@MainActor @Sendable ([String]) -> Void)
    var onAddPage: (@MainActor @Sendable (String?) -> Void)
    var onAddSource: (@MainActor @Sendable (String?) -> Void)
    var onNewFolder: (@MainActor @Sendable () -> Void)
    var onNewSubfolder: (@MainActor @Sendable (String) -> Void)
}

/// Carries the right-clicked node + the effective selection (all selected if
/// the right-click is inside the selection, otherwise just the clicked node)
/// to the `@objc` menu handlers. Mirrors `PagesMenuPayload`.
private struct BookmarksMenuPayload {
    let clicked: BookmarkNode
    let effectiveNodes: [BookmarkNode]
}

/// Payload for "Open With" app items on a bookmark row. Carries the chosen app
/// URL (or `nil` for "Other…") and the bookmark node. A class so it round-trips
/// through `NSMenuItem.representedObject`.
final class OpenWithBookmarkRef {
    let appURL: URL?
    let node: BookmarkNode
    init(appURL: URL?, node: BookmarkNode) {
        self.appURL = appURL
        self.node = node
    }
}

// MARK: - View controller

final class BookmarksOutlineViewController: NSViewController {
    var scrollView: NSScrollView!
    var outlineView: NSOutlineView!
    var store: WikiStoreModel?
    var fileProvider: FileProviderFacade?
    var callbacks: BookmarksCallbacks?

    /// Snapshot for change detection — covers all fields that affect rendering
    /// (id, parentID, position, kind, label, targetID), so renames, reorders,
    /// and reparents all trigger a reload.
    private var lastNodeCount = -1
    private var lastNodeSignature = ""

    /// Cached parent→children map (key `nil` = root). Rebuilt once per reload
    /// so data-source callbacks are O(1) lookups instead of O(n) filters.
    private var childrenMap: [String?: [BookmarkNode]] = [:]

    /// Tracks whether the initial expand-all has run. After that, reloads
    /// preserve the user's expand/collapse choices instead of force-expanding.
    private var hasPerformedInitialLoad = false

    /// When true, all folders are force-expanded on reload (search mode).
    var forceExpandAll = false

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        outlineView = BookmarksNSOutlineView()
        outlineView.dataSource = self
        outlineView.delegate = self
        // Required for the outline view to act as a drop target at all — without
        // this, validateDrop/acceptDrop are never called and no highlight shows.
        // The private bookmark-node-id type powers intra-tree reorder (a node id);
        // `.url` lets a `wiki://` link dragged out of a page/source body land
        // here (issue #169); the sidebar-item type lets the omnibox icon (and
        // sidebar rows via SwiftUI .draggable) drop a page/source/chat here to
        // create a bookmark. The bookmark-node-id type is a private UTType (not
        // `.string`) so WKWebView doesn't intercept bookmark drags (issue #385).
        let sidebarItemType = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        let bookmarkNodeType = NSPasteboard.PasteboardType("com.selfdrivingwiki.bookmark-node-id")
        outlineView.registerForDraggedTypes([bookmarkNodeType, .init("public.url"), sidebarItemType])
        // NSTableView/NSOutlineView is its own NSDraggingSource; there is no
        // delegate callback for this — the mask is configured imperatively.
        // Without it, the default local-drag mask is a multi-bit value that
        // never satisfies validateDrop's `.move` check below.
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 14
        outlineView.rowHeight = 24
        outlineView.doubleAction = #selector(onDoubleClick)
        outlineView.target = self
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = true
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: .init("bookmark"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Initial data load — outlineView is now available.
        reloadData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Data reload

    func needsReload(nodes: [BookmarkNode]) -> Bool {
        guard nodes.count == lastNodeCount else { return true }
        return nodeSignature(nodes) != lastNodeSignature
    }

    func reloadData(from nodes: [BookmarkNode]? = nil) {
        let nodes = nodes ?? (store?.bookmarkNodes ?? [])
        lastNodeCount = nodes.count
        lastNodeSignature = nodeSignature(nodes)

        // Rebuild the parent→children map once (M2: avoids O(n) filter per row).
        childrenMap.removeAll(keepingCapacity: true)
        for node in nodes {
            childrenMap[node.parentID, default: []].append(node)
        }
        // Sort each group by position.
        for key in childrenMap.keys {
            childrenMap[key]?.sort { $0.position < $1.position }
        }

        if !hasPerformedInitialLoad {
            // First load: expand all folders so the tree is fully visible.
            outlineView.reloadData()
            for node in nodes where node.kind == .folder {
                outlineView.expandItem(node)
            }
            hasPerformedInitialLoad = true
        } else if forceExpandAll {
            // Search mode: force-expand all folders so hits inside collapsed
            // folders are immediately visible.
            outlineView.reloadData()
            for node in nodes where node.kind == .folder {
                outlineView.expandItem(node)
            }
        } else {
            // Subsequent reloads: snapshot expanded state, reload, restore.
            let expandedIDs = Set(
                nodes.filter { outlineView.isItemExpanded($0) }.map(\.id)
            )
            outlineView.reloadData()
            for node in nodes where node.kind == .folder && expandedIDs.contains(node.id) {
                outlineView.expandItem(node)
            }
        }
    }

    /// Compact per-node signature covering all rendering-relevant fields.
    private func nodeSignature(_ nodes: [BookmarkNode]) -> String {
        nodes.map { "\($0.id)|\($0.parentID ?? "")|\($0.position)|\($0.kind.rawValue)|\($0.label ?? "")|\($0.targetID?.rawValue ?? "")" }
            .joined(separator: "\n")
    }

    // MARK: - Helpers

    private func children(of parentID: String?) -> [BookmarkNode] {
        childrenMap[parentID] ?? []
    }

    private func title(for node: BookmarkNode) -> String {
        guard let store else { return node.label ?? "(missing)" }
        if let label = node.label { return label }
        switch node.kind {
        case .pageRef:
            return node.targetID.flatMap { id in store.summaries.first { $0.id == id }?.title } ?? "(missing)"
        case .sourceRef:
            return node.targetID.flatMap { id in store.sources.first { $0.id == id }?.effectiveName } ?? "(missing)"
        case .chatRef:
            return node.targetID.flatMap { id in store.chats.first { $0.id == id }?.title } ?? "(missing)"
        case .folder:
            return node.label ?? "Untitled"
        }
    }

    private func iconName(for node: BookmarkNode) -> String {
        switch node.kind {
        case .folder: return "folder"
        case .pageRef:
            let isStale = node.targetID.flatMap { id in store?.summaries.first { $0.id == id } } == nil
            return isStale ? "exclamationmark.triangle" : ResourceKind.page.systemImageName
        case .sourceRef:
            let isStale = node.targetID.flatMap { id in store?.sources.first { $0.id == id } } == nil
            return isStale ? "exclamationmark.triangle" : ResourceKind.source.systemImageName
        case .chatRef:
            let isStale = node.targetID.flatMap { id in store?.chats.first { $0.id == id } } == nil
            return isStale ? "exclamationmark.triangle" : ResourceKind.chat.systemImageName
        }
    }

    // MARK: - Actions

    @objc private func onDoubleClick() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? BookmarkNode else { return }
        if item.kind == .folder {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            return
        }
        // Open page/source/chat ref.
        if let targetID = item.targetID {
            let sel: WikiSelection
            switch item.kind {
            case .pageRef: sel = .page(targetID)
            case .sourceRef: sel = .source(targetID)
            case .chatRef: sel = .chat(targetID)
            case .folder: return
            }
            callbacks?.onOpen([sel])
        }
    }
}

// MARK: - Data source

extension BookmarksOutlineViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return children(of: nil).count
        }
        guard let node = item as? BookmarkNode else { return 0 }
        return children(of: node.id).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let parentID = (item as? BookmarkNode)?.id
        return children(of: parentID)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? BookmarkNode else { return false }
        // All folders are expandable — even empty ones (matching the tree
        // builder's `children: []` contract for empty folders).
        return node.kind == .folder
    }

    // Drag and drop.
    // The writer carries TWO representations so one drag can serve two drop
    // targets: the private `com.selfdrivingwiki.bookmark-node-id` type powers
    // intra-tree reorder, and the resolved-target payload list lets the row be
    // dropped onto the welcome screen to open whatever the bookmark points at
    // (issue #133). A folder's payload list is every page/source reachable
    // underneath it, so dropping a folder opens its full contents as tabs
    // (issue #150).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? BookmarkNode else { return nil }
        let payloads: [SidebarDragPayload]
        switch node.kind {
        case .pageRef, .sourceRef, .chatRef:
            if let targetID = node.targetID, let kind = dragKind(for: node.kind) {
                payloads = [SidebarDragPayload(kind: kind, id: targetID.rawValue)]
            } else {
                payloads = []
            }
        case .folder:
            payloads = leafPayloads(under: node.id)
        }
        DebugLog.tabs("[drag] bookmark pasteboardWriterForItem node=\(node.id) kind=\(node.kind) payloadCount=\(payloads.count)")
        return SidebarDragPasteboardItem(payloads: payloads, bookmarkNodeID: node.id)
    }

    /// Recursively collects the resolved page/source/chat target for every leaf
    /// reachable under `folderID`, walking into nested subfolders too.
    private func leafPayloads(under folderID: String) -> [SidebarDragPayload] {
        children(of: folderID).flatMap { child -> [SidebarDragPayload] in
            guard let targetID = child.targetID, let kind = dragKind(for: child.kind) else {
                return child.kind == .folder ? leafPayloads(under: child.id) : []
            }
            return [SidebarDragPayload(kind: kind, id: targetID.rawValue)]
        }
    }

    /// Maps a leaf `BookmarkNodeKind` to its `SidebarDragPayload.Kind`; `nil`
    /// for `.folder` (folders have no target of their own to drag).
    private func dragKind(for kind: BookmarkNodeKind) -> SidebarDragPayload.Kind? {
        switch kind {
        case .pageRef: return .page
        case .sourceRef: return .source
        case .chatRef: return .chat
        case .folder: return nil
        }
    }

    // MARK: - Wiki-link drop (issue #169)

    /// Read the first `wiki://…` href from a drag pasteboard. WebKit's default
    /// link drag may offer the href under `.url`, `.string`, or both, so check
    /// each. Returns nil for an intra-tree bookmark reorder (which now uses a
    /// private `com.selfdrivingwiki.bookmark-node-id` type, not `.string`).
    private static func firstWikiLinkURL(from pb: NSPasteboard) -> URL? {
        let schemePrefix = "\(WikiLinkMarkdown.scheme)://"
        for type in [NSPasteboard.PasteboardType("public.url"), NSPasteboard.PasteboardType.string] {
            guard let raw = pb.string(forType: type),
                  raw.hasPrefix(schemePrefix),
                  let url = URL(string: raw) else { continue }
            return url
        }
        return nil
    }

    /// Read the first `SidebarDragPayloadList` from a drag pasteboard. The
    /// omnibox icon (and sidebar rows via SwiftUI `.draggable`) write payload
    /// JSON under the `wikiSidebarItem` UTType. Returns nil for non-sidebar
    /// drags (wiki-link drops, intra-tree reorders).
    private static func firstSidebarPayload(from pb: NSPasteboard) -> SidebarDragPayloadList? {
        let sidebarType = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        guard let data = pb.data(forType: sidebarType),
              let list = try? JSONDecoder().decode(SidebarDragPayloadList.self, from: data) else {
            return nil
        }
        return list
    }

    /// Resolve a dropped sidebar-item payload and insert a bookmark node for
    /// each target (page/source/chat) at the drop position. Mirrors the
    /// wiki-link drop's parent/position resolution.
    @discardableResult
    private func acceptSidebarPayloadDrop(_ list: SidebarDragPayloadList,
                                          onto item: Any?, atIndex index: Int,
                                          store: WikiStoreModel) -> Bool {
        let parentID: String?
        let basePosition: Int
        if let folder = item as? BookmarkNode, folder.kind == .folder {
            parentID = folder.id
            basePosition = index >= 0 ? index : children(of: folder.id).count
        } else if let leaf = item as? BookmarkNode {
            parentID = leaf.parentID
            basePosition = index >= 0 ? index : leaf.position
        } else {
            parentID = nil
            basePosition = index >= 0 ? index : children(of: nil).count
        }
        var position = basePosition
        for payload in list.items {
            let pageID = PageID(rawValue: payload.id)
            switch payload.kind {
            case .page:
                store.addPageRef(parentID: parentID, pageID: pageID, position: position)
            case .source:
                store.addSourceRef(parentID: parentID, sourceID: pageID, position: position)
            case .chat:
                store.addChatRef(parentID: parentID, chatID: pageID, position: position)
            }
            DebugLog.tabs("[drop] sidebar-item bookmark created: kind=\(payload.kind) id=\(payload.id) parentID=\(parentID ?? "root") position=\(position)")
            position += 1
        }
        return true
    }

    /// Resolve a dropped `wiki://` link to a page/source and insert a bookmark
    /// node for it at the drop position. Mirrors `WikiReaderView.linkRoute(for:)`'s
    /// resolution: title from `WikiLinkMarkdown.target`, kind from `resolvedKind`,
    /// then the same `pageID(forTitle:)` / `sourceID(forDisplayName:)` lookups the
    /// click handler uses. The insertion position follows the same rules as the
    /// intra-tree reorder: a precise `index >= 0` lands between siblings (the
    /// store shifts later siblings down); `-1` (drop *on* an item) appends.
    @discardableResult
    private func acceptWikiLinkDrop(url: URL, onto item: Any?, atIndex index: Int,
                                    store: WikiStoreModel) -> Bool {
        guard let title = WikiLinkMarkdown.target(from: url),
              let kind = WikiLinkMarkdown.resolvedKind(from: url) else {
            DebugLog.tabs("[drop] wiki-link bookmark drop: not a resolvable wiki URL \(url.absoluteString)")
            return false
        }
        // Chat links are not bookmarkable yet — reject the drop.
        guard kind != .chat else { return false }
        // Phase 5: prefer the canonical `?id=<ULID>` when present (a direct id —
        // no name resolution, stable across renames); validate it names a real
        // row so a bookmark to a since-deleted target falls back to title-based
        // resolution instead of storing a dead id. Legacy `?title=`-only URLs
        // resolve by name as before.
        let targetID: PageID?
        if let id = WikiLinkMarkdown.id(from: url) {
            let exists = (kind == .page)
                ? store.summaries.contains { $0.id == id }
                : store.sources.contains { $0.id == id }
            targetID = exists ? id
                : (kind == .page ? store.pageID(forTitle: title) : store.sourceID(forDisplayName: title))
        } else {
            targetID = (kind == .page)
                ? store.pageID(forTitle: title)
                : store.sourceID(forDisplayName: title)
        }
        guard let resolved = targetID else {
            DebugLog.tabs("[drop] wiki-link bookmark drop: title \"\(title)\" did not resolve to a \(kind) id")
            return false
        }
        // Resolve parent + insertion index. `index == -1` (NSOutlineViewDropOnItemIndex)
        // means "drop on the item", so append inside it (or, for a leaf, at the
        // leaf's own slot); `index >= 0` means "insert between siblings".
        let parentID: String?
        let position: Int
        if let folder = item as? BookmarkNode, folder.kind == .folder {
            parentID = folder.id
            position = index >= 0 ? index : children(of: folder.id).count
        } else if let leaf = item as? BookmarkNode {
            parentID = leaf.parentID
            position = index >= 0 ? index : leaf.position
        } else {
            // Root.
            parentID = nil
            position = index >= 0 ? index : children(of: nil).count
        }
        switch kind {
        case .page:   store.addPageRef(parentID: parentID, pageID: resolved, position: position)
        case .source: store.addSourceRef(parentID: parentID, sourceID: resolved, position: position)
        case .chat:
            // Chat refs aren't a bookmark target yet (no `addChatRef`); reject
            // the drop so a chat wiki-link drag is a no-op rather than a crash.
            return false
        }
        DebugLog.tabs("[drop] wiki-link bookmark created: kind=\(kind) title=\"\(title)\" parentID=\(parentID ?? "root") position=\(position)")
        return true
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        DebugLog.tabs("BookmarksOutlineView.validateDrop: mask=\(info.draggingSourceOperationMask.rawValue) item=\((item as? BookmarkNode)?.id ?? "root") index=\(index)")
        // Wiki-link drop: a `wiki://page?title=…` / `wiki://source?title=…`
        // anchor dragged out of rendered page/source content (issue #169). The
        // default WKWebView link drag vends the href as `.url`/`.string`; accept
        // it as `.copy` so `acceptDrop` creates a bookmark at the target.
        if Self.firstWikiLinkURL(from: info.draggingPasteboard) != nil {
            if item == nil { return .copy }                       // root
            if (item as? BookmarkNode)?.kind == .folder { return .copy }
            if item is BookmarkNode { return .copy }              // leaf → sibling
            return []
        }
        // Sidebar-item drop: a page/source/chat dragged from the omnibox icon
        // or a sidebar row via SwiftUI .draggable. Accept as `.copy` so
        // `acceptDrop` creates a bookmark node for the payload's target.
        if Self.firstSidebarPayload(from: info.draggingPasteboard) != nil {
            if item == nil { return .copy }                       // root
            if (item as? BookmarkNode)?.kind == .folder { return .copy }
            if item is BookmarkNode { return .copy }              // leaf → sibling
            return []
        }
        guard info.draggingSourceOperationMask.contains(.move) else { return [] }
        // Allow drop onto folders or between rows.
        if let folder = item as? BookmarkNode, folder.kind == .folder {
            return .move
        }
        if item == nil {
            return .move
        }
        // Allow reorder between siblings.
        if item is BookmarkNode {
            return .move
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        DebugLog.tabs("BookmarksOutlineView.acceptDrop: item=\((item as? BookmarkNode)?.id ?? "root") index=\(index)")
        guard let store else { return false }

        // Wiki-link drop → create a bookmark pointing at the link's target
        // (issue #169). Resolved before the intra-tree reorder path, which reads
        // the private bookmark-node-id type (not `.string`).
        if let url = Self.firstWikiLinkURL(from: info.draggingPasteboard) {
            return acceptWikiLinkDrop(url: url, onto: item, atIndex: index, store: store)
        }

        // Sidebar-item drop → create a bookmark for each page/source/chat in
        // the payload (omnibox icon drag, or a SwiftUI .draggable sidebar row).
        if let payloadList = Self.firstSidebarPayload(from: info.draggingPasteboard) {
            return acceptSidebarPayloadDrop(payloadList, onto: item, atIndex: index, store: store)
        }

        // Multi-selection is allowed, so a reorder drag can carry more than one
        // node id — one pasteboard item per dragged row.
        let bookmarkNodeType = NSPasteboard.PasteboardType("com.selfdrivingwiki.bookmark-node-id")
        let draggedIDs = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: bookmarkNodeType) }
        guard !draggedIDs.isEmpty else { return false }

        func moveAll(toParentID parentID: String?, startingAt position: Int) -> Bool {
            var position = position
            var succeeded = true
            for id in draggedIDs {
                succeeded = store.moveBookmarkNode(id: id, toParentID: parentID, position: position) && succeeded
                position += 1
            }
            return succeeded
        }

        if let folder = item as? BookmarkNode, folder.kind == .folder {
            return moveAll(toParentID: folder.id, startingAt: children(of: folder.id).count)
        }

        if let leaf = item as? BookmarkNode {
            // Reorder within the same parent.
            return moveAll(toParentID: leaf.parentID, startingAt: index >= 0 ? index : leaf.position)
        }

        // Root append
        return moveAll(toParentID: nil, startingAt: children(of: nil).count)
    }
}

// MARK: - Delegate

extension BookmarksOutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BookmarkNode else { return nil }
        let cellID = NSUserInterfaceItemIdentifier("bookmark-cell")

        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentTintColor = .controlAccentColor
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.imageView?.image = NSImage(systemSymbolName: iconName(for: node), accessibilityDescription: nil)
        cell.textField?.stringValue = title(for: node)

        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    // Context menu via right-click
    func outlineView(_ outlineView: NSOutlineView, menuFor item: Any) -> NSMenu? {
        guard let clicked = item as? BookmarkNode else { return nil }

        // Standard macOS semantics: right-click inside the selection acts on
        // the whole selection; right-click outside it acts on the clicked row only.
        let clickedRow = outlineView.row(forItem: clicked)
        let selectedRows = outlineView.selectedRowIndexes
        let inSelection = selectedRows.contains(clickedRow)
        let effectiveNodes: [BookmarkNode] = inSelection
            ? selectedRows.compactMap { outlineView.item(atRow: $0) as? BookmarkNode }
            : [clicked]
        let payload = BookmarksMenuPayload(clicked: clicked, effectiveNodes: effectiveNodes)

        let isBatch = effectiveNodes.count > 1
        let count = effectiveNodes.count

        // Leaf nodes (pageRef / sourceRef / chatRef) that can be opened as tabs.
        let openableNodes = effectiveNodes.filter {
            $0.kind == .pageRef || $0.kind == .sourceRef || $0.kind == .chatRef
        }
        let openCount = openableNodes.count

        let menu = NSMenu()

        // "Go to Original" — reveal the bookmark's target in its sidebar
        // section (Pages/Sources/Chats) without opening a reader tab. Uses the
        // same "Show in List" mechanism (requestSidebarReveal) as the
        // detail-view buttons. Single selection only, openable leaves only
        // (pageRef / sourceRef / chatRef) — folders have no target, and batches
        // are ambiguous about which item to reveal.
        if !isBatch, !openableNodes.isEmpty {
            menu.addItem(menuItem("Go to Original",
                                  systemImage: "arrow.turn.up.right",
                                  action: #selector(goToOriginalAction(_:)),
                                  payload: payload))
            menu.addItem(.separator())
        }

        // Open / Open in Background — only when there are openable leaves.
        if !openableNodes.isEmpty {
            menu.addItem(menuItem(
                isBatch ? "Open \(openCount)" : "Open",
                systemImage: "arrow.up.forward.app",
                action: #selector(openAction(_:)), payload: payload))
            menu.addItem(menuItem(
                isBatch ? "Open \(openCount) in Background" : "Open in Background",
                systemImage: "dock.arrow.down.rectangle",
                action: #selector(openBackgroundAction(_:)), payload: payload))

            // Open With — single item only (batch open-with is ambiguous).
            if !isBatch, fileProvider?.path != nil {
                let type: UTType
                switch clicked.kind {
                case .pageRef:
                    type = OpenWithMenu.pageContentType
                case .sourceRef:
                    let src = store?.sources.first { $0.id == clicked.targetID }
                    type = OpenWithMenu.contentType(mimeType: src?.mimeType, filename: src?.filename)
                case .chatRef:
                    type = OpenWithMenu.pageContentType
                case .folder:
                    type = .data
                }
                let submenu = OpenWithMenu.build(
                    contentType: type,
                    target: self,
                    action: #selector(openWithAppAction(_:)),
                    payload: { appURL in
                        OpenWithBookmarkRef(appURL: appURL, node: clicked)
                    })
                let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right",
                                       accessibilityDescription: nil)
                parent.submenu = submenu
                menu.addItem(parent)
            }
            menu.addItem(.separator())
        }

        // Edit — single item only.
        if !isBatch {
            menu.addItem(menuItem("Edit…", systemImage: "pencil",
                                  action: #selector(editAction(_:)), payload: payload))
        }

        // Add Page / Add Source — folder, single item only.
        if !isBatch && clicked.kind == .folder {
            menu.addItem(.separator())
            menu.addItem(menuItem("Add Page…", systemImage: ResourceKind.page.systemImageName,
                                  action: #selector(addPageAction(_:)), payload: payload))
            menu.addItem(menuItem("Add Source…", systemImage: ResourceKind.source.systemImageName,
                                  action: #selector(addSourceAction(_:)), payload: payload))
        }

        // Delete — always available, operates on all effective nodes.
        menu.addItem(.separator())
        menu.addItem(menuItem(
            isBatch ? "Delete \(count)" : "Delete",
            systemImage: "trash",
            action: #selector(deleteAction(_:)), payload: payload))

        return menu
    }

    private func menuItem(_ title: String, systemImage: String,
                          action: Selector, payload: BookmarksMenuPayload) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.target = self
        item.representedObject = payload
        return item
    }

    // MARK: - Menu actions

    @objc private func openAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload else { return }
        let selections = openableSelections(from: payload.effectiveNodes)
        if !selections.isEmpty { callbacks?.onOpen(selections) }
    }

    @objc private func openBackgroundAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload else { return }
        let selections = openableSelections(from: payload.effectiveNodes)
        if !selections.isEmpty { callbacks?.onOpenBackground(selections) }
    }

    /// Filters effective nodes to openable leaves and maps them to `WikiSelection`.
    private func openableSelections(from nodes: [BookmarkNode]) -> [WikiSelection] {
        nodes.compactMap { revealSelection(for: $0) }
    }

    /// Maps a single bookmark node to the `WikiSelection` its target represents.
    /// Returns `nil` for folders or nodes missing a target id. Shared by "Open"
    /// and "Go to Original" so the kind→selection mapping lives in one place.
    private func revealSelection(for node: BookmarkNode) -> WikiSelection? {
        guard let targetID = node.targetID else { return nil }
        switch node.kind {
        case .pageRef:   return .page(targetID)
        case .sourceRef: return .source(targetID)
        case .chatRef:   return .chat(targetID)
        case .folder:    return nil
        }
    }

    @objc private func goToOriginalAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload,
              let sel = revealSelection(for: payload.clicked) else { return }
        DebugLog.tabs("Bookmarks goToOriginal: kind=\(payload.clicked.kind) targetID=\(payload.clicked.targetID?.rawValue ?? "nil")")
        callbacks?.onGoToOriginal(sel)
    }

    @objc private func openWithAppAction(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? OpenWithBookmarkRef,
              let targetID = ref.node.targetID, let fileProvider else { return }
        Task {
            let picked: URL?
            if let appURL = ref.appURL {
                picked = appURL
            } else {
                picked = await AppPicker.pick()
            }
            guard let appURL = picked else { return }
            switch ref.node.kind {
            case .pageRef:
                await fileProvider.openPage(id: targetID, with: appURL)
            case .sourceRef:
                await fileProvider.openSource(id: targetID, with: appURL)
            case .chatRef:
                await fileProvider.openChat(id: targetID, with: appURL)
            case .folder:
                break
            }
        }
    }

    @objc private func editAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload else { return }
        callbacks?.onEdit(payload.clicked.id)
    }

    @objc private func addPageAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload else { return }
        callbacks?.onAddPage(payload.clicked.id)
    }

    @objc private func addSourceAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload else { return }
        callbacks?.onAddSource(payload.clicked.id)
    }

    @objc private func deleteAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? BookmarksMenuPayload else { return }
        deleteNodes(payload.effectiveNodes.map(\.id))
    }

    /// Keyboard-delete entry point (Backspace / forward-Delete on selected
    /// rows). Builds the effective node list from the outline's current
    /// selection and routes through the same `onDelete` callback the
    /// context-menu "Delete" item uses — no separate deletion path (#744).
    @objc func deleteSelection() {
        let nodes = outlineView.selectedRowIndexes.compactMap {
            outlineView.item(atRow: $0) as? BookmarkNode
        }
        guard !nodes.isEmpty else { return }
        deleteNodes(nodes.map(\.id))
    }

    /// Shared deletion seam for both the context-menu "Delete" action and the
    /// keyboard Delete/Backspace path (`deleteSelection`).
    private func deleteNodes(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        callbacks?.onDelete(ids)
    }
}

// MARK: - NSOutlineView subclass for context menu support

final class BookmarksNSOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        let item = self.item(atRow: row)
        return (self.delegate as? BookmarksOutlineViewController)?.outlineView(self, menuFor: item ?? "")
    }

    // Keyboard-delete (#744): when the outline view is first responder (no
    // text field editing) and at least one row is selected, forward Delete /
    // Backspace to the controller's deletion seam — the same `onDelete`
    // callback the context-menu "Delete" item uses. A text field that is
    // editing is the first responder and consumes `deleteBackward` /
    // `deleteForward` itself, so this override only fires when no editor is
    // active — renames/edit fields keep Backspace for text editing.
    override func deleteBackward(_ sender: Any?) {
        guard selectedRow != -1 else {
            super.deleteBackward(sender)
            return
        }
        (delegate as? BookmarksOutlineViewController)?.deleteSelection()
    }

    override func deleteForward(_ sender: Any?) {
        guard selectedRow != -1 else {
            super.deleteForward(sender)
            return
        }
        (delegate as? BookmarksOutlineViewController)?.deleteSelection()
    }
}
