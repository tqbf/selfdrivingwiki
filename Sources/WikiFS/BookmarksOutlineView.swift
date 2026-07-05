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
    let fileProvider: FileProviderSpike
    var onOpen: ([WikiSelection]) -> Void
    var onOpenBackground: ([WikiSelection]) -> Void
    var onEdit: (String) -> Void
    var onDelete: ([String]) -> Void
    var onAddPage: (String?) -> Void
    var onAddSource: (String?) -> Void
    var onNewFolder: () -> Void
    var onNewSubfolder: (String) -> Void

    func makeNSViewController(context: Context) -> BookmarksOutlineViewController {
        let vc = BookmarksOutlineViewController()
        vc.store = store
        vc.fileProvider = fileProvider
        vc.callbacks = .init(
            onOpen: onOpen, onOpenBackground: onOpenBackground,
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
            onEdit: onEdit, onDelete: onDelete,
            onAddPage: onAddPage, onAddSource: onAddSource,
            onNewFolder: onNewFolder, onNewSubfolder: onNewSubfolder
        )
        let needs = vc.needsReload(nodes: nodes)
        DebugLog.tabs("BookmarksOutlineView.updateNSVC: nodes=\(nodes.count) needsReload=\(needs)")
        if needs {
            vc.reloadData(from: nodes)
        }
    }
}

// MARK: - Callbacks

struct BookmarksCallbacks {
    var onOpen: ([WikiSelection]) -> Void
    var onOpenBackground: ([WikiSelection]) -> Void
    var onEdit: (String) -> Void
    var onDelete: ([String]) -> Void
    var onAddPage: (String?) -> Void
    var onAddSource: (String?) -> Void
    var onNewFolder: () -> Void
    var onNewSubfolder: (String) -> Void
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
    var fileProvider: FileProviderSpike?
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
        outlineView.registerForDraggedTypes([.string])
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
        case .folder:
            return node.label ?? "Untitled"
        }
    }

    private func iconName(for node: BookmarkNode) -> String {
        switch node.kind {
        case .folder: return "folder"
        case .pageRef:
            let isStale = node.targetID.flatMap { id in store?.summaries.first { $0.id == id } } == nil
            return isStale ? "exclamationmark.triangle" : "doc.text"
        case .sourceRef:
            let isStale = node.targetID.flatMap { id in store?.sources.first { $0.id == id } } == nil
            return isStale ? "exclamationmark.triangle" : "doc"
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
        // Open page/source ref.
        if let targetID = item.targetID {
            let sel: WikiSelection = item.kind == .pageRef ? .page(targetID) : .source(targetID)
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
    // targets: the `.string` node id powers intra-tree reorder (`acceptDrop`
    // reads `pb.string(forType: .string)`), and the resolved-target payload list
    // lets the row be dropped onto the welcome screen to open whatever the
    // bookmark points at (issue #133). A folder's payload list is every
    // page/source reachable underneath it, so dropping a folder opens its full
    // contents as tabs (issue #150).
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? BookmarkNode else { return nil }
        let payloads: [SidebarDragPayload]
        switch node.kind {
        case .pageRef, .sourceRef:
            if let targetID = node.targetID {
                let kind: SidebarDragPayload.Kind = (node.kind == .pageRef) ? .page : .source
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

    /// Recursively collects the resolved page/source target for every leaf
    /// reachable under `folderID`, walking into nested subfolders too.
    private func leafPayloads(under folderID: String) -> [SidebarDragPayload] {
        children(of: folderID).flatMap { child -> [SidebarDragPayload] in
            switch child.kind {
            case .pageRef, .sourceRef:
                guard let targetID = child.targetID else { return [] }
                let kind: SidebarDragPayload.Kind = (child.kind == .pageRef) ? .page : .source
                return [SidebarDragPayload(kind: kind, id: targetID.rawValue)]
            case .folder:
                return leafPayloads(under: child.id)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        DebugLog.tabs("BookmarksOutlineView.validateDrop: mask=\(info.draggingSourceOperationMask.rawValue) item=\((item as? BookmarkNode)?.id ?? "root") index=\(index)")
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
        // Multi-selection is allowed, so a reorder drag can carry more than one
        // node id — one pasteboard item per dragged row.
        let draggedIDs = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: .string) }
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

        // Leaf nodes (pageRef / sourceRef) that can be opened as tabs.
        let openableNodes = effectiveNodes.filter { $0.kind == .pageRef || $0.kind == .sourceRef }
        let openCount = openableNodes.count

        let menu = NSMenu()

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
            menu.addItem(menuItem("Add Page…", systemImage: "doc.text",
                                  action: #selector(addPageAction(_:)), payload: payload))
            menu.addItem(menuItem("Add Source…", systemImage: "doc",
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
        nodes.compactMap { node -> WikiSelection? in
            guard node.kind == .pageRef || node.kind == .sourceRef,
                  let targetID = node.targetID else { return nil }
            return node.kind == .pageRef ? .page(targetID) : .source(targetID)
        }
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
        callbacks?.onDelete(payload.effectiveNodes.map(\.id))
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
}
