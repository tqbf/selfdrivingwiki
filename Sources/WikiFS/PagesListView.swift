import AppKit
import SwiftUI
import WikiFSCore

// MARK: - SwiftUI bridge

/// Native `NSTableView` for the pages sidebar. Replaces a SwiftUI `List` whose
/// per-row `.onTapGesture(count: 2)` made every single-click wait on SwiftUI's
/// gesture arbitrator (the documented "severe selection-update latency on
/// macOS"). Native `mouseDown` selection is instant; `doubleAction` is a
/// separate recognizer that never delays the single click. Mirrors
/// `BookmarksOutlineView` structurally, but flat (`NSTableView`, not
/// `NSOutlineView`).
struct PagesListView: NSViewControllerRepresentable {
    let store: WikiStoreModel
    let fileProvider: FileProviderSpike
    let manager: WikiManager
    let launcher: AgentLauncher
    let callbacks: PagesListCallbacks

    func makeNSViewController(context: Context) -> PagesListViewController {
        let vc = PagesListViewController()
        vc.store = store
        vc.fileProvider = fileProvider
        vc.manager = manager
        vc.launcher = launcher
        vc.callbacks = callbacks
        // Don't reloadData here — loadView hasn't run yet (mirrors
        // BookmarksOutlineView.makeNSViewController). Initial load in viewDidLoad.
        return vc
    }

    func updateNSViewController(_ vc: PagesListViewController, context: Context) {
        vc.store = store
        vc.fileProvider = fileProvider
        vc.manager = manager
        vc.launcher = launcher
        vc.callbacks = callbacks
        // Read the @Observable props here so SwiftUI re-invokes this method
        // when they change (the reload-trigger contract).
        let visible = store.searchQuery.isEmpty ? store.summaries : store.searchResults
        _ = store.pageSortOrder
        let needs = vc.needsReload(visible)
        DebugLog.tabs("PagesListView.updateNSVC: count=\(visible.count) needsReload=\(needs)")
        if needs { vc.reloadData(from: visible) }
        // Always reconcile highlight to the active tab (cheap; guarded inside).
        vc.reconcileHighlight(activeSelection: store.activeTab?.selection)
        // Explicit "Show In List" reveal (issue #183): the pending target is
        // read here so SwiftUI re-invokes this method when it changes. When the
        // target matches this section, scroll to + select the row (bypassing the
        // multi-select guard) and consume so it fires once.
        if let pending = store.pendingSidebarReveal, case .page(let id) = pending {
            _ = vc.revealAndSelect(id: id)
            store.consumePendingSidebarReveal()
        }
    }
}

// MARK: - Callbacks

struct PagesListCallbacks {
    /// Open (foreground tab). Single-click-double passes one id; context-menu
    /// "Open N" passes the effective selection.
    var onOpen: ([PageID]) -> Void
    /// Open externally via the File Provider (single or batch). Pass an app URL
    /// to launch a specific editor (chosen from the "Open With" submenu), or nil
    /// for the default handler.
    var onOpenExternal: (_ ids: [PageID], _ appURL: URL?) -> Void
    var onOpenBackground: ([PageID]) -> Void
    var onShare: ([PageID]) -> Void
    var onReveal: (PageID) -> Void
    var onLint: ([PageID]) -> Void
    var onRename: (WikiPageSummary) -> Void
    var onDelete: ([PageID]) -> Void
    /// Bookmark a multi-row selection (or a single row) into a folder the user
    /// picks in the target-picker sheet. Opens `BookmarkTargetPickerSheet`.
    var onAddToBookmarks: ([PageID]) -> Void
}

/// Carries the right-clicked row + the effective selection (selected ∪ clicked)
/// to the `@objc` menu handlers.
private struct PagesMenuPayload {
    let clicked: WikiPageSummary
    let effectiveIDs: [PageID]
}

// MARK: - View controller

final class PagesListViewController: NSViewController {
    var scrollView: NSScrollView!
    var tableView: PagesNSTableView!
    var store: WikiStoreModel?
    var fileProvider: FileProviderSpike?
    var manager: WikiManager?
    var launcher: AgentLauncher?
    var callbacks: PagesListCallbacks?

    private var items: [WikiPageSummary] = []
    private var lastCount = -1
    private var lastSignature = ""
    /// Re-entrancy guard: selecting a row programmatically must not loop back.
    private var isReconcilingHighlight = false

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        tableView = PagesNSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.backgroundColor = .clear
        tableView.doubleAction = #selector(onDoubleClick)
        tableView.target = self
        // Implementing `pasteboardWriterForRow` opts the table into drag-out; the
        // source operation mask still has to be set explicitly or the default
        // (empty/multi-bit) mask blocks the drag from starting. `.copy` because
        // dragging a page row onto the welcome screen opens a reference, not a
        // move (the row isn't removed).
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadData()
    }

    // MARK: - Reload

    func needsReload(_ rows: [WikiPageSummary]) -> Bool {
        guard rows.count == lastCount else { return true }
        return signature(rows) != lastSignature
    }

    func reloadData(from rows: [WikiPageSummary]? = nil) {
        let rows = rows ?? items
        items = rows
        lastCount = rows.count
        lastSignature = signature(rows)
        tableView.reloadData()
    }

    private func signature(_ rows: [WikiPageSummary]) -> String {
        rows.map { "\($0.id.rawValue)|\($0.title)|\($0.updatedAt.timeIntervalSince1970)" }
            .joined(separator: "\n")
    }

    // MARK: - Highlight sync

    /// Reflect the active tab's selection into the table highlight. Called every
    /// `updateNSViewController`. Only acts when the table is in single-selection
    /// state so user multi-selects (Cmd/Shift) aren't clobbered.
    func reconcileHighlight(activeSelection: WikiSelection?) {
        guard !isReconcilingHighlight, tableView.selectedRowIndexes.count <= 1 else { return }
        switch activeSelection {
        case .page(let id):
            guard let row = items.firstIndex(where: { $0.id == id }) else { return }
            if tableView.selectedRow != row {
                isReconcilingHighlight = true
                tableView.selectRowIndexes(IndexSet([row]), byExtendingSelection: false)
                isReconcilingHighlight = false
            }
        default:
            if tableView.selectedRow >= 0 {
                isReconcilingHighlight = true
                tableView.deselectAll(self)
                isReconcilingHighlight = false
            }
        }
    }

    // MARK: - Reveal ("Show In List")

    /// Explicit "Show In List" reveal: select the target row and scroll it into
    /// view. Unlike ``reconcileHighlight``, this bypasses the multi-select guard
    /// (an explicit user action should win over a Cmd/Shift selection) and always
    /// scrolls. Returns whether the row was found in the current items.
    @discardableResult
    func revealAndSelect(id: PageID) -> Bool {
        guard let row = items.firstIndex(where: { $0.id == id }) else { return false }
        isReconcilingHighlight = true
        tableView.selectRowIndexes(IndexSet([row]), byExtendingSelection: false)
        isReconcilingHighlight = false
        tableView.scrollRowToVisible(row)
        return true
    }

    // MARK: - Double-click

    @objc private func onDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        // Double-click opens the clicked page only (mirrors bookmarks).
        callbacks?.onOpen([items[row].id])
    }
}

// MARK: - Data source

extension PagesListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < items.count else { return nil }
        let id = items[row].id.rawValue
        DebugLog.tabs("[drag] page pasteboardWriterForRow row=\(row) id=\(id)")
        return SidebarDragPayload(kind: .page, id: id).makePasteboardWriter()
    }
}

// MARK: - Delegate

extension PagesListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let summary = items[row]
        let cellID = NSUserInterfaceItemIdentifier("page-cell")

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
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

        cell.imageView?.image = NSImage(systemSymbolName: ResourceKind.page.systemImageName, accessibilityDescription: nil)
        cell.textField?.stringValue = summary.title.isEmpty ? "Untitled" : summary.title
        cell.toolTip = summary.title.isEmpty ? "Untitled" : summary.title
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // Swipe-to-delete (macOS 11+; app targets macOS 15). Replaces SwiftUI
    // `.swipeActions(edge: .trailing)`.
    func tableView(_ tableView: NSTableView,
                   rowActionsForRow row: Int,
                   edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard edge == .trailing, row >= 0, row < items.count else { return [] }
        let delete = NSTableViewRowAction(style: .destructive, title: "Delete") { [weak self] _, r in
            guard let self, r < self.items.count else { return }
            self.callbacks?.onDelete([self.items[r].id])
        }
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return [delete]
    }
}

// MARK: - Context menu

extension PagesListViewController {
    /// Built lazily on right-click. Effective selection = selected ∪ clicked
    /// (right-clicked row joins the batch even if not already selected —
    /// preserves the prior SwiftUI `selectedPageIDs.contains(summary.id)` rule).
    func menuForRow(_ row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        let clicked = items[row]
        // Standard macOS semantics: right-click inside the selection acts on the
        // whole selection; right-click outside it acts on the clicked row only.
        // Matches the prior `selectedPageIDs.contains(summary.id)` gate.
        let selected = tableView.selectedRowIndexes
        let inSelection = selected.contains(row)
        let effectiveIDs = (inSelection ? Array(selected) : [row])
            .sorted().map { items[$0].id }
        let isBatch = effectiveIDs.count > 1
        let count = effectiveIDs.count
        let payload = PagesMenuPayload(clicked: clicked, effectiveIDs: effectiveIDs)
        let pathMounted = fileProvider?.path != nil

        let menu = NSMenu()

        menu.addItem(menuItem(
            title: isBatch ? "Open \(count) Pages" : "Open",
            systemImage: "arrow.up.forward.app", action: #selector(openAction(_:)), payload: payload))

        menu.addItem(menuItem(
            title: isBatch ? "Open \(count) in Background" : "Open in Background",
            systemImage: "dock.arrow.down.rectangle", action: #selector(openBackgroundAction(_:)),
            payload: payload))

        if pathMounted {
            let submenu = OpenWithMenu.build(
                contentType: OpenWithMenu.pageContentType,
                target: self,
                action: #selector(openWithAppAction(_:)),
                payload: { appURL in
                    OpenWithIDsRef(appURL: appURL, ids: payload.effectiveIDs)
                })
            let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right",
                                   accessibilityDescription: nil)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(menuItem(
            title: isBatch ? "Add \(count) Pages to Bookmarks…" : "Add to Bookmarks…",
            systemImage: ResourceKind.bookmark.systemImageName, action: #selector(addToBookmarksAction(_:)), payload: payload))

        if isBatch {
            menu.addItem(menuItem(
                title: "Share \(count) Pages",
                systemImage: "square.and.arrow.up", action: #selector(shareAction(_:)), payload: payload))
        } else if pathMounted {
            menu.addItem(menuItem(
                title: "Share",
                systemImage: "square.and.arrow.up", action: #selector(shareAction(_:)), payload: payload))
        }

        if !isBatch, pathMounted {
            menu.addItem(menuItem(
                title: "Reveal in Finder",
                systemImage: "folder", action: #selector(revealAction(_:)), payload: payload))
        }

        menu.addItem(.separator())

        let lint = menuItem(
            title: isBatch ? "Lint \(count) Pages" : "Lint Page",
            systemImage: "checkmark.seal", action: #selector(lintAction(_:)), payload: payload)
        // No edit-lock disable — CAS prevents data races; lint queues via the gate.
        menu.addItem(lint)

        menu.addItem(.separator())
        if !isBatch {
            menu.addItem(menuItem(
                title: "Rename",
                systemImage: "pencil", action: #selector(renameAction(_:)), payload: payload))
            if isCurrentHomePage(clicked.id) {
                menu.addItem(menuItem(
                    title: "Clear Home Page",
                    systemImage: "house.slash", action: #selector(clearHomePageAction(_:)), payload: payload))
            } else {
                menu.addItem(menuItem(
                    title: "Set as Home Page",
                    systemImage: "house", action: #selector(setHomePageAction(_:)), payload: payload))
            }
        }

        menu.addItem(menuItem(
            title: isBatch ? "Delete \(count) Pages" : "Delete",
            systemImage: "trash", action: #selector(deleteAction(_:)), payload: payload))

        return menu
    }

    /// Whether `pageID` is the active wiki's configured home page (issue #280) —
    /// decides "Set as Home Page" vs. "Clear Home Page" in the context menu.
    private func isCurrentHomePage(_ pageID: PageID) -> Bool {
        guard let manager, let wikiID = manager.activeWikiID,
              let wiki = manager.wikis.first(where: { $0.id == wikiID }) else { return false }
        return wiki.homePageID == pageID
    }

    private func menuItem(title: String, systemImage: String,
                          action: Selector, payload: PagesMenuPayload) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.target = self
        item.representedObject = payload
        return item
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onOpen(p.effectiveIDs) }
    }
    @objc private func openWithAppAction(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? OpenWithIDsRef else { return }
        Task { [weak self] in
            let picked: URL?
            if let appURL = ref.appURL {
                picked = appURL
            } else {
                picked = await AppPicker.pick()
            }
            guard let appURL = picked else { return }
            self?.callbacks?.onOpenExternal(ref.ids, appURL)
        }
    }
    @objc private func openBackgroundAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onOpenBackground(p.effectiveIDs) }
    }
    @objc private func shareAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onShare(p.effectiveIDs) }
    }
    @objc private func revealAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onReveal(p.clicked.id) }
    }
    @objc private func lintAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onLint(p.effectiveIDs) }
    }
    @objc private func renameAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onRename(p.clicked) }
    }
    @objc private func setHomePageAction(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? PagesMenuPayload,
              let manager, let wikiID = manager.activeWikiID else { return }
        manager.setHomePage(id: wikiID, pageID: p.clicked.id)
    }
    @objc private func clearHomePageAction(_ sender: NSMenuItem) {
        guard let manager, let wikiID = manager.activeWikiID else { return }
        manager.setHomePage(id: wikiID, pageID: nil)
    }
    @objc private func deleteAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload { callbacks?.onDelete(p.effectiveIDs) }
    }
    @objc private func addToBookmarksAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PagesMenuPayload {
            callbacks?.onAddToBookmarks(p.effectiveIDs)
        }
    }
}

// MARK: - NSTableView subclass

final class PagesNSTableView: NSTableView {
    /// Right-click → per-row context menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return (self.delegate as? PagesListViewController)?.menuForRow(row)
    }

    /// Cmd+A → select all rows, scoped to this table.
    ///
    /// `performKeyEquivalent(with:)` is dispatched across the window's entire
    /// view hierarchy for every key-down event — not just to the current first
    /// responder — so a naive override here would steal Cmd+A from other first
    /// responders in the same window (notably the omnibox/address bar). We
    /// therefore only act when this table view (or a descendant, e.g. an inline
    /// field editor) is actually the current first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "a" else {
            return super.performKeyEquivalent(with: event)
        }
        guard isSelfOrDescendantFirstResponder() else {
            return super.performKeyEquivalent(with: event)
        }
        self.selectAll(self)
        return true
    }
}
