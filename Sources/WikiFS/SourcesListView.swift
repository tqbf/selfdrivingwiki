import AppKit
import SwiftUI
import WikiFSCore

// MARK: - SwiftUI bridge

/// Native `NSTableView` for the sources sidebar. Mirrors `PagesListView` (and
/// the bookmarks pattern): native mouseDown selection + `doubleAction`, no
/// SwiftUI gesture arbitration. Cell adds byte size + an
/// extracting/ingesting/ingested status indicator; the context menu carries
/// Ingest / Extract (with re-ingest confirmation) on top of the shared
/// open/share/rename/delete actions. Double-click opens an in-app source tab
/// (mirroring pages/bookmarks); the "Open In…" item routes through the File
/// Provider for an external launch.
struct SourcesListView: NSViewControllerRepresentable {
    let store: WikiStoreModel
    let fileProvider: FileProviderSpike
    let manager: WikiManager
    let launcher: AgentLauncher
    let ingestingSourceIDs: Set<PageID>
    let extractingSourceIDs: Set<PageID>
    /// The filtered+searched source list, computed by the container.
    let sources: [SourceSummary]
    let callbacks: SourcesListCallbacks

    func makeNSViewController(context: Context) -> SourcesListViewController {
        let vc = SourcesListViewController()
        vc.store = store
        vc.fileProvider = fileProvider
        vc.manager = manager
        vc.launcher = launcher
        vc.callbacks = callbacks
        vc.ingestingIDs = ingestingSourceIDs
        vc.extractingIDs = extractingSourceIDs
        return vc
    }

    func updateNSViewController(_ vc: SourcesListViewController, context: Context) {
        vc.store = store
        vc.fileProvider = fileProvider
        vc.manager = manager
        vc.launcher = launcher
        vc.callbacks = callbacks
        vc.ingestingIDs = ingestingSourceIDs
        vc.extractingIDs = extractingSourceIDs
        // Read @Observable props so SwiftUI re-invokes this method on change.
        _ = store.sourceSearchQuery
        _ = store.sources
        let needs = vc.needsReload(sources)
        DebugLog.tabs("SourcesListView.updateNSVC: count=\(sources.count) needsReload=\(needs)")
        if needs { vc.reloadData(from: sources) }
        vc.reconcileHighlight(activeSelection: store.activeTab?.selection)
    }
}

// MARK: - Callbacks

/// One item for the Extract action: enough to drive `launcher.extractPDF` per
/// source without the controller knowing about the launcher.
struct SourceExtractItem {
    let id: PageID
    let filename: String
    let data: Data
}

struct SourcesListCallbacks {
    /// Open an in-app source tab (single or batch), foreground.
    var onOpen: ([PageID]) -> Void
    /// Open externally via the File Provider (single or batch). Pass an app URL
    /// to launch a specific editor (chosen from the "Open With" submenu), or nil
    /// for the default handler.
    var onOpenExternal: (_ ids: [PageID], _ appURL: URL?) -> Void
    /// Open an in-app background tab.
    var onOpenBackground: ([PageID]) -> Void
    var onShare: ([PageID]) -> Void
    var onReveal: (PageID) -> Void
    /// Ingest directly (no already-ingested members in the set).
    var onIngest: ([PageID]) -> Void
    /// Some already-ingested sources are in the set — surface the "Ingest
    /// Again?" confirmation. `names` lists the already-ingested sources.
    var onIngestNeedsConfirmation: (_ ids: [PageID], _ names: [String]) -> Void
    var onExtract: ([SourceExtractItem]) -> Void
    var onRename: (SourceSummary) -> Void
    var onDelete: ([PageID]) -> Void
}

private struct SourcesMenuPayload {
    let clicked: SourceSummary
    let effective: [SourceSummary]
}

// MARK: - Cell

/// A source row cell: leading MIME icon, title (middle-truncated), byte size,
/// and a trailing status that swaps between a spinner (extracting/ingesting)
/// and a glyph (ingested/ready). Built once, configured on reuse.
final class SourceListCellView: NSTableCellView {
    let mimeIcon = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let sizeField = NSTextField(labelWithString: "")
    let statusSpinner = NSProgressIndicator()
    let statusGlyph = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        for v in [mimeIcon, titleField, sizeField, statusSpinner, statusGlyph] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        mimeIcon.contentTintColor = .controlAccentColor
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sizeField.font = .systemFont(ofSize: 11)
        sizeField.textColor = .secondaryLabelColor
        sizeField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isIndeterminate = true
        statusSpinner.isHidden = true

        NSLayoutConstraint.activate([
            mimeIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            mimeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            mimeIcon.widthAnchor.constraint(equalToConstant: 16),
            mimeIcon.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: mimeIcon.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusGlyph.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusGlyph.widthAnchor.constraint(equalToConstant: 14),
            statusGlyph.heightAnchor.constraint(equalToConstant: 14),

            statusSpinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusSpinner.widthAnchor.constraint(equalToConstant: 14),
            statusSpinner.heightAnchor.constraint(equalToConstant: 14),

            sizeField.trailingAnchor.constraint(equalTo: statusGlyph.leadingAnchor, constant: -4),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: sizeField.leadingAnchor, constant: -8),
        ])
    }

    func configure(source: SourceSummary, hasBeenIngested: Bool,
                   isIngesting: Bool, isExtracting: Bool) {
        mimeIcon.image = NSImage(systemSymbolName: Self.symbol(for: source),
                                 accessibilityDescription: nil)
        let name = source.displayName ?? (source.filename.isEmpty ? "Untitled" : source.filename)
        titleField.stringValue = name
        toolTip = name
        sizeField.stringValue = Self.sizeFormatter.string(fromByteCount: Int64(source.byteSize))

        let status = SourceRowStatus.status(isExtracting: isExtracting,
                                            isIngesting: isIngesting,
                                            hasBeenIngested: hasBeenIngested)
        switch status {
        case .extracting:
            statusGlyph.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.startAnimation(nil)
            toolTip = "Extracting…"
        case .ingesting:
            statusGlyph.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.startAnimation(nil)
            toolTip = "Ingesting…"
        case .ingested:
            statusSpinner.isHidden = true
            statusSpinner.stopAnimation(nil)
            statusGlyph.isHidden = false
            statusGlyph.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                        accessibilityDescription: nil)
            statusGlyph.contentTintColor = .systemGreen
            toolTip = "Ingested into the wiki"
        case .ready:
            statusSpinner.isHidden = true
            statusSpinner.stopAnimation(nil)
            statusGlyph.isHidden = false
            statusGlyph.image = NSImage(systemSymbolName: "circle.dashed",
                                        accessibilityDescription: nil)
            statusGlyph.contentTintColor = .secondaryLabelColor
            toolTip = "Ready to ingest into the wiki"
        }
    }

    private static func symbol(for source: SourceSummary) -> String {
        if source.mimeType == "application/pdf" { return "doc.richtext" }
        if let mime = source.mimeType, mime.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}

// MARK: - View controller

final class SourcesListViewController: NSViewController {
    var scrollView: NSScrollView!
    var tableView: SourcesNSTableView!
    var store: WikiStoreModel?
    var fileProvider: FileProviderSpike?
    var manager: WikiManager?
    var launcher: AgentLauncher?
    var callbacks: SourcesListCallbacks?
    var ingestingIDs: Set<PageID> = []
    var extractingIDs: Set<PageID> = []

    private var items: [SourceSummary] = []
    private var lastCount = -1
    private var lastSignature = ""
    private var isReconcilingHighlight = false

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        tableView = SourcesNSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.backgroundColor = .clear
        tableView.doubleAction = #selector(onDoubleClick)
        tableView.target = self
        // Enable drag-out (see PagesListView for the mask rationale). `.copy`
        // because dragging a source row opens a reference rather than moving it.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadData()
    }

    func needsReload(_ rows: [SourceSummary]) -> Bool {
        guard rows.count == lastCount else { return true }
        return signature(rows) != lastSignature
    }

    func reloadData(from rows: [SourceSummary]? = nil) {
        let rows = rows ?? items
        items = rows
        lastCount = rows.count
        lastSignature = signature(rows)
        tableView.reloadData()
    }

    private func signature(_ rows: [SourceSummary]) -> String {
        rows.map { s in
            let ingested = (store?.isSourceIngested(s) ?? false) ? 1 : 0
            let ingesting = ingestingIDs.contains(s.id) ? 1 : 0
            let extracting = extractingIDs.contains(s.id) ? 1 : 0
            return "\(s.id.rawValue)|\(s.effectiveName)|\(s.byteSize)|\(s.version)|\(ingested)|\(ingesting)|\(extracting)"
        }.joined(separator: "\n")
    }

    func reconcileHighlight(activeSelection: WikiSelection?) {
        guard !isReconcilingHighlight, tableView.selectedRowIndexes.count <= 1 else { return }
        switch activeSelection {
        case .source(let id):
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

    @objc private func onDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        callbacks?.onOpen([items[row].id])
    }
}

// MARK: - Data source

extension SourcesListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < items.count else { return nil }
        let id = items[row].id.rawValue
        DebugLog.tabs("[drag] source pasteboardWriterForRow row=\(row) id=\(id)")
        return SidebarDragPayload(kind: .source, id: id).makePasteboardWriter()
    }
}

// MARK: - Delegate

extension SourcesListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let source = items[row]
        let cellID = NSUserInterfaceItemIdentifier("source-cell")
        let cell: SourceListCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? SourceListCellView {
            cell = reused
        } else {
            cell = SourceListCellView()
            cell.identifier = cellID
        }
        cell.configure(source: source,
                       hasBeenIngested: store?.isSourceIngested(source) ?? false,
                       isIngesting: ingestingIDs.contains(source.id),
                       isExtracting: extractingIDs.contains(source.id))
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

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

extension SourcesListViewController {
    func menuForRow(_ row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        let clicked = items[row]
        // Right-click inside the selection → batch over the selection; outside
        // → single, on the clicked row only (standard macOS + prior behavior).
        let selected = tableView.selectedRowIndexes
        let inSelection = selected.contains(row)
        let effective = (inSelection ? Array(selected) : [row])
            .sorted().compactMap { items[$0] }
        let isMulti = effective.count > 1
        let count = effective.count
        let payload = SourcesMenuPayload(clicked: clicked, effective: effective)

        let menu = NSMenu()

        menu.addItem(item(
            title: isMulti ? "Open \(count) Sources" : "Open",
            systemImage: "arrow.up.forward.app", action: #selector(openAction(_:)), payload: payload))

        menu.addItem(item(
            title: isMulti ? "Open \(count) in Background" : "Open in Background",
            systemImage: "dock.arrow.down.rectangle", action: #selector(openBackgroundAction(_:)),
            payload: payload))

        if fileProvider?.path != nil {
            let type = OpenWithMenu.contentType(mimeType: clicked.mimeType,
                                                filename: clicked.filename)
            let submenu = OpenWithMenu.build(
                contentType: type,
                target: self,
                action: #selector(openWithAppAction(_:)),
                payload: { appURL in
                    OpenWithIDsRef(appURL: appURL, ids: payload.effective.map(\.id))
                })
            let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right",
                                   accessibilityDescription: nil)
            parent.submenu = submenu
            menu.addItem(parent)
        }

        if isMulti {
            menu.addItem(item(title: "Share \(count) Sources", systemImage: "square.and.arrow.up",
                              action: #selector(shareAction(_:)), payload: payload))
        } else if fileProvider?.path != nil {
            menu.addItem(item(title: "Share", systemImage: "square.and.arrow.up",
                              action: #selector(shareAction(_:)), payload: payload))
        }

        if !isMulti, fileProvider?.path != nil {
            menu.addItem(item(title: "Reveal in Finder", systemImage: "folder",
                              action: #selector(revealAction(_:)), payload: payload))
        }

        menu.addItem(.separator())
        menu.addItem(item(
            title: isMulti ? "Ingest \(count) Sources" : "Ingest",
            systemImage: "text.badge.plus", action: #selector(ingestAction(_:)), payload: payload))

        let extractable = effective.filter { canExtract($0) }
        if isMulti {
            if !extractable.isEmpty {
                menu.addItem(.separator())
                menu.addItem(item(title: "Extract \(extractable.count) Sources",
                                  systemImage: "doc.plaintext", action: #selector(extractAction(_:)),
                                  payload: payload))
            }
        } else if canExtract(clicked) {
            menu.addItem(.separator())
            menu.addItem(item(title: "Extract Markdown", systemImage: "doc.plaintext",
                              action: #selector(extractAction(_:)), payload: payload))
        }

        menu.addItem(.separator())
        if !isMulti {
            menu.addItem(item(title: "Rename", systemImage: "pencil",
                              action: #selector(renameAction(_:)), payload: payload))
        }
        menu.addItem(item(title: isMulti ? "Delete \(count) Sources" : "Delete",
                          systemImage: "trash", action: #selector(deleteAction(_:)), payload: payload))

        return menu
    }

    private func canExtract(_ source: SourceSummary) -> Bool {
        source.mimeType == "application/pdf"
            && store?.processedMarkdownHead(for: source) == nil
    }

    private func item(title: String, systemImage: String,
                      action: Selector, payload: SourcesMenuPayload) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        i.target = self
        i.representedObject = payload
        return i
    }

    @objc private func openAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? SourcesMenuPayload { callbacks?.onOpen(p.effective.map(\.id)) }
    }
    @objc private func openWithAppAction(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? OpenWithIDsRef else { return }
        Task { [weak self] in
            // nil appURL = the "Other…" item → present an app picker.
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
        if let p = sender.representedObject as? SourcesMenuPayload { callbacks?.onOpenBackground(p.effective.map(\.id)) }
    }
    @objc private func shareAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? SourcesMenuPayload { callbacks?.onShare(p.effective.map(\.id)) }
    }
    @objc private func revealAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? SourcesMenuPayload { callbacks?.onReveal(p.clicked.id) }
    }
    @objc private func ingestAction(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? SourcesMenuPayload, let store else { return }
        let ids = p.effective.map(\.id)
        let reingestNames = p.effective.compactMap { s -> String? in
            guard store.isSourceIngested(s) else { return nil }
            return s.displayName ?? s.filename
        }
        if !reingestNames.isEmpty {
            callbacks?.onIngestNeedsConfirmation(ids, reingestNames)
        } else {
            callbacks?.onIngest(ids)
        }
    }
    @objc private func extractAction(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? SourcesMenuPayload, let store else { return }
        let toExtract = p.effective.compactMap { s -> SourceExtractItem? in
            guard s.mimeType == "application/pdf",
                  store.processedMarkdownHead(for: s) == nil,
                  let data = store.sourceBytes(id: s.id) else { return nil }
            return SourceExtractItem(id: s.id, filename: s.filename, data: data)
        }
        guard !toExtract.isEmpty else { return }
        callbacks?.onExtract(toExtract)
    }
    @objc private func renameAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? SourcesMenuPayload { callbacks?.onRename(p.clicked) }
    }
    @objc private func deleteAction(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? SourcesMenuPayload { callbacks?.onDelete(p.effective.map(\.id)) }
    }
}

// MARK: - NSTableView subclass

final class SourcesNSTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return (self.delegate as? SourcesListViewController)?.menuForRow(row)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "a" {
            self.selectAll(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
