import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSCore

// MARK: - SwiftUI bridge

/// Native `NSTableView` for the chats sidebar. Replaces the SwiftUI
/// `List(selection:)` (single-select only) with a table that supports native
/// multi-selection (Shift / Cmd / right-click), drag-out, and batch context
/// menus — matching `PagesListView` / `SourcesListView` structurally.
///
/// Single-click selects; double-click opens. The active tab's chat is
/// reconciled into the highlight on every SwiftUI update (mirrors Pages).
struct ChatsListView: NSViewControllerRepresentable {
    let store: WikiStoreModel
    /// The chat daemon coordinator — drives the live "responding…" indicator
    /// on rows (Phase C4: chat is daemon-hosted). `nil` when the daemon is
    /// unavailable; rows then never show the live badge.
    let chatDaemon: ChatDaemonCoordinator?
    let callbacks: ChatsListCallbacks

    func makeNSViewController(context: Context) -> ChatsListViewController {
        let vc = ChatsListViewController()
        vc.store = store
        vc.chatDaemon = chatDaemon
        vc.callbacks = callbacks
        return vc
    }

    func updateNSViewController(_ vc: ChatsListViewController, context: Context) {
        vc.store = store
        vc.chatDaemon = chatDaemon
        vc.callbacks = callbacks
        let visible = store.chatSearchQuery.isEmpty ? store.chats : store.chatSearchResults
        let needs = vc.needsReload(visible)
        DebugLog.tabs("ChatsListView.updateNSVC: count=\(visible.count) needsReload=\(needs)")
        if needs { vc.reloadData(from: visible) }
        vc.reconcileHighlight(activeSelection: store.activeTab?.selection)
        if let pending = store.pendingSidebarReveal, case .chat(let id) = pending {
            _ = vc.revealAndSelect(id: id)
            store.consumePendingSidebarReveal()
        }
    }
}

// MARK: - Callbacks

struct ChatsListCallbacks {
    /// Open (foreground tab). Context-menu "Open N" passes the effective
    /// selection.
    var onOpen: ([PageID]) -> Void
    /// Open in a background tab. Single or batch.
    var onOpenBackground: ([PageID]) -> Void
    var onRename: (ChatSummary) -> Void
    var onDelete: ([PageID]) -> Void
}

/// Carries the right-clicked row + the effective selection (selected ∪ clicked)
/// to the `@objc` menu handlers.
private struct ChatsMenuPayload {
    let clicked: ChatSummary
    let effectiveIDs: [PageID]
}

// MARK: - View controller

final class ChatsListViewController: NSViewController {
    var scrollView: NSScrollView!
    var tableView: ChatsNSTableView!
    var store: WikiStoreModel?
    /// The daemon coordinator (Phase C4) — drives the per-row live indicator
    /// via `isChatRunning(_:)`.
    var chatDaemon: ChatDaemonCoordinator?
    var callbacks: ChatsListCallbacks?

    private var items: [ChatSummary] = []
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

        tableView = ChatsNSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.backgroundColor = .clear
        tableView.doubleAction = #selector(onDoubleClick)
        tableView.target = self
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
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

    func needsReload(_ rows: [ChatSummary]) -> Bool {
        guard rows.count == lastCount else { return true }
        return signature(rows) != lastSignature
    }

    func reloadData(from rows: [ChatSummary]? = nil) {
        let rows = rows ?? items
        items = rows
        lastCount = rows.count
        lastSignature = signature(rows)
        tableView.reloadData()
    }

    private func signature(_ rows: [ChatSummary]) -> String {
        rows.map {
            "\($0.id.rawValue)|\($0.title)|\($0.updatedAt.timeIntervalSince1970)|\($0.summary ?? "")"
        }.joined(separator: "\n")
    }

    // MARK: - Highlight sync

    /// Reflect the active tab's selection into the table highlight. Called every
    /// `updateNSViewController`. Only acts when the table is in single-selection
    /// state so user multi-selects (Cmd/Shift) aren't clobbered.
    func reconcileHighlight(activeSelection: WikiSelection?) {
        guard !isReconcilingHighlight, tableView.selectedRowIndexes.count <= 1 else { return }
        switch activeSelection {
        case .chat(let id):
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
    /// scrolls.
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
        callbacks?.onOpen([items[row].id])
    }

    // MARK: - Live indicator

    /// A row is live when the daemon reports its chat as running/generating
    /// (Phase C4: replaces the single chatLauncher activeChatID/isGenerating
    /// check with the coordinator's per-chat aggregate, which also covers chats
    /// the daemon is running that the app hasn't opened).
    private func isLive(_ chat: ChatSummary) -> Bool {
        chatDaemon?.isChatRunning(chat.id.rawValue) ?? false
    }
}

// MARK: - Data source

extension ChatsListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < items.count else { return nil }
        return SidebarDragPayload(kind: .chat, id: items[row].id.rawValue).makePasteboardWriter()
    }
}

// MARK: - Delegate

extension ChatsListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let chat = items[row]
        let cellID = NSUserInterfaceItemIdentifier("chat-cell")

        let cell: ChatsCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? ChatsCellView {
            cell = reused
        } else {
            cell = ChatsCellView()
            cell.identifier = cellID
        }
        cell.configure(chat: chat, isLive: isLive(chat))
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 36 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    // Swipe-to-delete (macOS 11+; app targets macOS 15).
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

extension ChatsListViewController {
    /// Built lazily on right-click. Effective selection = selected ∪ clicked
    /// (right-clicked row joins the batch even if not already selected —
    /// standard macOS semantics, mirroring `PagesListViewController`).
    func menuForRow(_ row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        let clicked = items[row]
        let selected = tableView.selectedRowIndexes
        let inSelection = selected.contains(row)
        let effectiveIDs = (inSelection ? Array(selected) : [row])
            .sorted().map { items[$0].id }
        let isBatch = effectiveIDs.count > 1
        let count = effectiveIDs.count
        let payload = ChatsMenuPayload(clicked: clicked, effectiveIDs: effectiveIDs)

        let menu = NSMenu()

        menu.addItem(menuItem(
            title: isBatch ? "Open \(count) Chats" : "Open",
            systemImage: "arrow.up.forward.app", action: #selector(openAction(_:)), payload: payload))

        menu.addItem(menuItem(
            title: isBatch ? "Open \(count) in Background" : "Open in Background",
            systemImage: "dock.arrow.down.rectangle", action: #selector(openBackgroundAction(_:)),
            payload: payload))

        menu.addItem(.separator())

        if !isBatch {
            menu.addItem(menuItem(
                title: "Rename Chat…",
                systemImage: "pencil", action: #selector(renameAction(_:)), payload: payload))
        }

        menu.addItem(menuItem(
            title: isBatch ? "Delete \(count) Chats" : "Delete",
            systemImage: "trash", action: #selector(deleteAction(_:)), payload: payload))

        return menu
    }

    private func menuItem(title: String, systemImage: String,
                          action: Selector, payload: ChatsMenuPayload) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        item.target = self
        item.representedObject = payload
        return item
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ChatsMenuPayload { callbacks?.onOpen(p.effectiveIDs) }
    }
    @objc private func openBackgroundAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ChatsMenuPayload { callbacks?.onOpenBackground(p.effectiveIDs) }
    }
    @objc private func renameAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ChatsMenuPayload { callbacks?.onRename(p.clicked) }
    }
    @objc private func deleteAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? ChatsMenuPayload { callbacks?.onDelete(p.effectiveIDs) }
    }
}

// MARK: - Cell

/// A chat row cell: leading icon, title (body, medium weight, truncated), and a
/// subtitle that adapts between "responding…" (live, tinted), the chat summary,
/// and the relative timestamp. Built once, configured on reuse.
final class ChatsCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let liveDot = NSImageView()
    private let liveLabel = NSTextField(labelWithString: "responding…")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        for v in [iconView, titleField, subtitleField, liveDot, liveLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        iconView.contentTintColor = .secondaryLabelColor

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.cell?.truncatesLastVisibleLine = true
        subtitleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        liveDot.image = NSImage(systemSymbolName: "circle.fill",
                                accessibilityDescription: nil)
        liveDot.contentTintColor = .controlAccentColor
        liveLabel.font = .systemFont(ofSize: 11)
        liveLabel.textColor = .controlAccentColor
        liveLabel.isHidden = true
        liveDot.isHidden = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: trailingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),

            liveDot.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            liveDot.centerYAnchor.constraint(equalTo: subtitleField.centerYAnchor),
            liveDot.widthAnchor.constraint(equalToConstant: 6),
            liveDot.heightAnchor.constraint(equalToConstant: 6),

            liveLabel.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 3),
            liveLabel.centerYAnchor.constraint(equalTo: subtitleField.centerYAnchor),
            liveLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(chat: ChatSummary, isLive: Bool) {
        iconView.image = NSImage(systemSymbolName: ResourceKind.chat.systemImageName,
                                  accessibilityDescription: nil)
        let title = chat.title.isEmpty ? "New Chat" : chat.title
        titleField.stringValue = title
        toolTip = title

        if isLive {
            subtitleField.isHidden = true
            liveDot.isHidden = false
            liveLabel.isHidden = false
        } else {
            liveDot.isHidden = true
            liveLabel.isHidden = true
            subtitleField.isHidden = false
            if let summary = chat.summary {
                subtitleField.stringValue = summary
            } else {
                subtitleField.stringValue = chat.updatedAt.formatted(.relative(presentation: .named))
            }
        }
    }
}

// MARK: - NSTableView subclass

final class ChatsNSTableView: NSTableView {
    /// Right-click → per-row context menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return (self.delegate as? ChatsListViewController)?.menuForRow(row)
    }

    /// Cmd+A → select all rows, scoped to this table (mirrors `PagesNSTableView`).
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
