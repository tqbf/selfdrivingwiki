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
    let fileProvider: FileProviderSpike
    var onOpen: (WikiSelection) -> Void
    var onEdit: (String) -> Void
    var onDelete: (String) -> Void
    var onAddPage: (String?) -> Void
    var onAddSource: (String?) -> Void
    var onNewFolder: () -> Void
    var onNewSubfolder: (String) -> Void

    func makeNSViewController(context: Context) -> BookmarksOutlineViewController {
        let vc = BookmarksOutlineViewController()
        vc.store = store
        vc.fileProvider = fileProvider
        vc.callbacks = .init(
            onOpen: onOpen, onEdit: onEdit, onDelete: onDelete,
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
            onOpen: onOpen, onEdit: onEdit, onDelete: onDelete,
            onAddPage: onAddPage, onAddSource: onAddSource,
            onNewFolder: onNewFolder, onNewSubfolder: onNewSubfolder
        )
        let nodes = store.bookmarkNodes
        let needs = vc.needsReload(nodes: nodes)
        DebugLog.tabs("BookmarksOutlineView.updateNSVC: nodes=\(nodes.count) needsReload=\(needs)")
        if needs {
            vc.reloadData(from: nodes)
        }
    }
}

// MARK: - Callbacks

struct BookmarksCallbacks {
    var onOpen: (WikiSelection) -> Void
    var onEdit: (String) -> Void
    var onDelete: (String) -> Void
    var onAddPage: (String?) -> Void
    var onAddSource: (String?) -> Void
    var onNewFolder: () -> Void
    var onNewSubfolder: (String) -> Void
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
        outlineView.allowsMultipleSelection = false
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
            callbacks?.onOpen(sel)
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
    // reads `pb.string(forType: .string)`), and the resolved-target payload lets
    // the row be dropped onto the welcome screen to open whatever the bookmark
    // points at (issue #133). Folders have no target, so they carry only the
    // reorder id.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? BookmarkNode else { return nil }
        var payload: SidebarDragPayload?
        if let targetID = node.targetID,
           node.kind == .pageRef || node.kind == .sourceRef {
            let kind: SidebarDragPayload.Kind = (node.kind == .pageRef) ? .page : .source
            payload = SidebarDragPayload(kind: kind, id: targetID.rawValue)
        }
        return SidebarDragPasteboardItem(payload: payload, bookmarkNodeID: node.id)
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
        let pb = info.draggingPasteboard
        guard let draggedID = pb.string(forType: .string) else { return false }

        if let folder = item as? BookmarkNode, folder.kind == .folder {
            let count = children(of: folder.id).count
            return store.moveBookmarkNode(id: draggedID, toParentID: folder.id, position: count)
        }

        if let leaf = item as? BookmarkNode {
            // Reorder within the same parent.
            let position = index >= 0 ? index : leaf.position
            return store.moveBookmarkNode(id: draggedID, toParentID: leaf.parentID, position: position)
        }

        // Root append
        let count = children(of: nil).count
        return store.moveBookmarkNode(id: draggedID, toParentID: nil, position: count)
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
        guard let node = item as? BookmarkNode else { return nil }
        let menu = NSMenu()

        if node.kind == .pageRef || node.kind == .sourceRef {
            let openItem = NSMenuItem(title: "Open", action: #selector(openAction(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = node
            menu.addItem(openItem)

            let openBgItem = NSMenuItem(title: "Open in Background", action: #selector(openBackgroundAction(_:)), keyEquivalent: "")
            openBgItem.target = self
            openBgItem.representedObject = node
            menu.addItem(openBgItem)

            if fileProvider?.path != nil {
                let type: UTType
                switch node.kind {
                case .pageRef:
                    type = OpenWithMenu.pageContentType
                case .sourceRef:
                    let src = store?.sources.first { $0.id == node.targetID }
                    type = OpenWithMenu.contentType(mimeType: src?.mimeType, filename: src?.filename)
                case .folder:
                    type = .data
                }
                let submenu = OpenWithMenu.build(
                    contentType: type,
                    target: self,
                    action: #selector(openWithAppAction(_:)),
                    payload: { appURL in
                        OpenWithBookmarkRef(appURL: appURL, node: node)
                    })
                let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right",
                                       accessibilityDescription: nil)
                parent.submenu = submenu
                menu.addItem(parent)
            }
            menu.addItem(.separator())
        }

        let editItem = NSMenuItem(title: "Edit…", action: #selector(editAction(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = node
        menu.addItem(editItem)

        if node.kind == .folder {
            menu.addItem(.separator())
            let addPageItem = NSMenuItem(title: "Add Page…", action: #selector(addPageAction(_:)), keyEquivalent: "")
            addPageItem.target = self
            addPageItem.representedObject = node
            menu.addItem(addPageItem)

            let addSourceItem = NSMenuItem(title: "Add Source…", action: #selector(addSourceAction(_:)), keyEquivalent: "")
            addSourceItem.target = self
            addSourceItem.representedObject = node
            menu.addItem(addSourceItem)
        }

        menu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = node
        menu.addItem(deleteItem)

        return menu
    }

    // MARK: - Menu actions

    @objc private func openAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode,
              let targetID = node.targetID else { return }
        callbacks?.onOpen(node.kind == .pageRef ? .page(targetID) : .source(targetID))
    }

    @objc private func openBackgroundAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode,
              let targetID = node.targetID, let store else { return }
        let sel: WikiSelection = node.kind == .pageRef ? .page(targetID) : .source(targetID)
        store.openTabInBackground(sel)
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
        guard let node = sender.representedObject as? BookmarkNode else { return }
        callbacks?.onEdit(node.id)
    }

    @objc private func addPageAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode else { return }
        callbacks?.onAddPage(node.id)
    }

    @objc private func addSourceAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode else { return }
        callbacks?.onAddSource(node.id)
    }

    @objc private func deleteAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? BookmarkNode else { return }
        callbacks?.onDelete(node.id)
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
