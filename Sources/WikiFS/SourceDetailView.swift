import SwiftUI
import WikiFSCore

/// Detail pane for one ingested source file. Shows metadata header + inline
/// content (markdown render, inline PDF, or tabbed Markdown⇄PDF when extraction
/// output exists). Cmd-E flips between reader and editor for processed markdown;
/// source bytes are never modified.
struct SourceDetailView: View {
    let file: SourceSummary
    let hasBeenIngested: Bool
    let isIngesting: Bool
    let isRunning: Bool
    /// `true` when any file (not necessarily this one) is mid-ingest — covers the
    /// PDF-conversion phase before the agent process starts, when `isRunning` is
    /// still `false`.
    let isAnySourceIngesting: Bool
    /// `true` when THIS file is mid-extraction via the ingest path (pdf2md running
    /// during an ingest of this file, before the agent spawns). Disables the
    /// standalone "Extract Markdown" button for this file only — pdf2md is safe to
    /// overlap with a claude run, so a query/ingest agent run does NOT disable it.
    let isThisFileExtracting: Bool
    /// `true` when the edit lock is held by an agent OTHER than the ingest agent
    /// (i.e., the query agent with "Allow wiki edits" checked). Disables the
    /// Ingest button so the user sees it's unavailable before clicking.
    let isEditLockedExternally: Bool
    let runIngest: (PageID) -> Void
    /// Shared launcher — used by the standalone `runExtraction` to take the
    /// extraction slot (so a standalone extract and an ingest-path extract serialize
    /// against each other) and to mirror this file's id into `extractingSourceIDs`
    /// so the sidebar row labels it "Extracting…".
    let launcher: AgentLauncher
    /// Resolves the selected extraction backend (local pdf2md / Claude / Docling
    /// Serve) for the standalone Extract button.
    let extractionCoordinator: ExtractionCoordinator
    let fileProvider: FileProviderSpike
    @Bindable var store: WikiStoreModel

    @AppStorage("editor.zoom") private var editorZoom = Double(ZoomScale.defaultScale)
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @AppStorage("isOutlineExpanded") private var isOutlineExpanded = false
    @State private var headVersion: SourceMarkdownVersion?
    @State private var isEditing = false
    @State private var editBuffer = ""
    @State private var isExtracting = false
    /// Tracks the active tab ID as of the last resolved update cycle — used to
    /// distinguish tab switches from in-tab file navigation.
    @State private var lastKnownActiveTabID: UUID? = nil
    /// Set when a tab switch targets a tab that was in edit mode but whose
    /// headVersion has not yet loaded. Cleared once headVersion arrives or
    /// the user navigates to a different file.
    @State private var shouldRestoreEditing = false
    /// Raised when the user taps Ingest on a document that has already been
    /// ingested — prompts before re-ingesting, since that may create duplicate
    /// pages. (Replaces the old always-on "already ingested" warning banner.)
    @State private var showReingestConfirmation = false
    @State private var selectedTab = FileContentTab.markdown
    /// Quote to highlight in the PDF view, set when a `[[source:Name#"…"]]` link
    /// targets an un-extracted PDF. Consumed from `store.pendingScrollAnchor`.
    @State private var pdfQuote: String?

    // Find bar state. Shared via environment (see `ContentView`) so the address
    // bar's "Find on Page…" menu item and Cmd+F drive the same model (#157).
    @Environment(FindModel.self) private var findModel
    @State private var findVersion = 0

    private enum FileContentTab: String, CaseIterable {
        case markdown = "Markdown"
        case pdf = "PDF"
        case split = "Split"
    }

    // MARK: - Computed

    private var isMarkdownNative: Bool {
        if let mime = file.mimeType { return mime.hasPrefix("text/") }
        return false
    }

    private var isPDF: Bool { file.mimeType == "application/pdf" }

    private var hasMarkdown: Bool { headVersion != nil }

    private var showTabs: Bool { isPDF && hasMarkdown }

    private var isMarkdownEditable: Bool {
        isMarkdownNative || hasMarkdown
    }

    private var displayName: String {
        let name = file.effectiveName
        return name.isEmpty ? "Untitled" : name
    }

    /// The markdown content currently shown (from processed head or native
    /// markdown source). Used as the find bar's search content.
    private var currentMarkdownContent: String? {
        if isEditing { return editBuffer }
        if let head = headVersion { return head.content }
        if isMarkdownNative, let data = store.sourceBytes(id: file.id) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private var findText: String? {
        guard findModel.isShowing,
              let content = findModel.content,
              findModel.currentMatchIndex > 0,
              findModel.currentMatchIndex <= findModel.matches.count
        else { return nil }
        let range = findModel.matches[findModel.currentMatchIndex - 1]
        return String(content[range])
    }

    /// 1-based current match index, forwarded to the reader so next/previous
    /// navigation targets distinct occurrences instead of always the first.
    private var findOccurrence: Int { findModel.currentMatchIndex }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            if showTabs, !isEditing {
                tabPicker
            }
            Divider().opacity(PageEditorMetrics.dividerOpacity)
            HStack(spacing: 0) {
                contentArea
                if isOutlineExpanded, let markdown = currentMarkdownContent {
                    PageOutlineView(markdown: markdown) { slug in
                        store.jumpToAnchorInCurrentSelection(slug)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            headVersion = store.processedMarkdownHead(for: file)
            lastKnownActiveTabID = store.activeTabID
        }
        .onChange(of: file.id) {
            // Navigating between ingested files REUSES this view instance (same
            // type/position), so SwiftUI preserves `@State` across the switch.
            // Reset every per-file @State here — including `isExtracting`, which
            // otherwise leaks A's "Extracting…" flag onto B's header. The header
            // spinner is additionally driven off the per-file `isThisFileExtracting`
            // launcher flag below, so it can never survive a navigation.
            flushEditIfDirty()
            isEditing = false
            isExtracting = false
            showReingestConfirmation = false
            headVersion = nil
            selectedTab = .markdown
            pdfQuote = nil
            // Cancel any pending edit-mode restoration so it doesn't apply to
            // the new file when its headVersion loads.
            shouldRestoreEditing = false
        }
        .task(id: file.id) { headVersion = store.processedMarkdownHead(for: file) }
        .task(id: PDFTaskKey(sourceID: file.id, anchorVersion: store.pendingScrollAnchorVersion)) {
            // Only consume for un-extracted PDFs (the markdown side handles
            // extracted PDFs via WikiReaderView). Double-check at consume time
            // since `hasMarkdown` may have changed since render.
            guard isPDF, !hasMarkdown else { return }
            if let frag = store.consumePendingScrollAnchor(for: store.selection) {
                pdfQuote = frag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        .onChange(of: store.selection) { flushEditIfDirty(); isEditing = false }
        .onChange(of: store.isAgentRunning) {
            if $1 { flushEditIfDirty(); isEditing = false }
        }
        .background { findShortcutButton }
        .overlay(alignment: .top) { findBarOverlay }
        .onChange(of: file.id) { findModel.dismiss() }
        .onChange(of: currentMarkdownContent) { _, newContent in
            findModel.content = newContent
            findModel.search()
        }
        .onChange(of: findModel.isShowing) { _, showing in
            if showing {
                findModel.content = currentMarkdownContent
                findModel.search()
            }
        }
        .onChange(of: findModel.currentMatchIndex) { _, _ in
            guard findModel.currentMatchIndex > 0 else { return }
            findVersion &+= 1
        }
        .onChange(of: store.activeTabID) { _, newID in
            lastKnownActiveTabID = newID
            let tab = store.tabs.first(where: { $0.id == newID })
            guard tab?.isEditing == true else {
                shouldRestoreEditing = false
                return
            }
            // Restore edit mode for the returning tab. If headVersion is already
            // loaded (same file, different tab), restore immediately; otherwise
            // defer until the async load completes.
            if let content = headVersion?.content {
                editBuffer = content
                isEditing = true
            } else {
                shouldRestoreEditing = true
            }
        }
        .onChange(of: headVersion) { _, newVersion in
            guard shouldRestoreEditing, let content = newVersion?.content else { return }
            editBuffer = content
            isEditing = true
            shouldRestoreEditing = false
        }
        .onChange(of: isEditing) { _, newValue in
            if let id = store.activeTabID {
                store.setTabEditing(tabID: id, isEditing: newValue)
            }
            if !newValue { shouldRestoreEditing = false }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            Label {
                EditableTitle(
                    title: displayName,
                    placeholder: "Untitled",
                    lineLimit: 2,
                    isDisabled: store.isAgentRunning || isEditLockedExternally,
                    onCommit: { store.renameSource(id: file.id, to: $0) }
                )
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                statusLabel
                Text(Self.sizeFormatter.string(fromByteCount: Int64(file.byteSize)))
                Text("Added \(file.createdAt, style: .date) at \(file.createdAt, style: .time)")
                if file.updatedAt != file.createdAt {
                    Text("Updated \(file.updatedAt, style: .date) at \(file.updatedAt, style: .time)")
                }
                if let head = headVersion, let label = Self.markdownOriginLabel(for: head.origin) {
                    Text("\(label) \(head.createdAt, style: .date) at \(head.createdAt, style: .time)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let zoteroItemKey = file.zoteroItemKey, !zoteroItemKey.isEmpty {
                zoteroOriginRow(key: zoteroItemKey)
            }

            HStack(spacing: 10) {
                if isEditing {
                    Button("Save Changes", systemImage: "checkmark.circle") {
                        commitEdit()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(store.isAgentRunning
                              || editBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (headVersion?.content == editBuffer))

                    Button("Cancel", systemImage: "xmark.circle") {
                        isEditing = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button {
                        isOutlineExpanded.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle Outline")
                } else {
                    Button(isIngesting ? "Ingesting…" : "Ingest into Wiki",
                           systemImage: "text.badge.plus") {
                        DebugLog.ingest("SourceDetailView: Ingest tapped — id=\(file.id.rawValue)")
                        if hasBeenIngested {
                            showReingestConfirmation = true
                        } else {
                            runIngest(file.id)
                        }
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isRunning || isIngesting || isAnySourceIngesting
                                  || isThisFileExtracting || isEditLockedExternally)
                        .confirmationDialog(
                            "Ingest Again?",
                            isPresented: $showReingestConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Ingest Again", role: .destructive) {
                                runIngest(file.id)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This document has already been ingested. Running ingest again may create duplicate pages.")
                        }
                    if isPDF, !hasMarkdown {
                        Button(isExtracting ? "Extracting…" : "Extract Markdown",
                               systemImage: "doc.plaintext") {
                            let task = Task {
                                defer { launcher.extractTask = nil }
                                await runExtraction()
                            }
                            launcher.extractTask = task
                        }
                        .disabled(isExtracting
                                  || isThisFileExtracting
                                  // Another file currently holds the extraction
                                  // slot — this extract would await it, so show
                                  // it as busy rather than letting the tap hang.
                                  || (launcher.isExtractionSlotBusy
                                      && !launcher.extractingSourceIDs.contains(file.id)))
                    }
                    if isMarkdownEditable {
                        Button("Edit", systemImage: "pencil") {
                            editBuffer = headVersion?.content ?? ""
                            isEditing = true
                        }
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(isRunning)
                    }
                    // Share — to the left of the Outline toggle.  Resolves the
                    // canonical URL from the daemon (like openSource) so the
                    // filename is human-readable and the URL is guaranteed
                    // to resolve.
                    if fileProvider.path != nil {
                        Button("Share", systemImage: "square.and.arrow.up") {
                            Task {
                                guard let url = await fileProvider.resolveSourceByNameURL(id: file.id) else { return }
                                DebugLog.fileprovider("Share source detail: \(url.lastPathComponent)")
                                let picker = NSSharingServicePicker(items: [url])
                                let mouseScreen = NSEvent.mouseLocation
                                guard let window = NSApplication.shared.keyWindow,
                                      let contentView = window.contentView else { return }
                                let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                                let viewPoint = contentView.convert(windowPoint, from: nil)
                                picker.show(
                                    relativeTo: NSRect(origin: viewPoint,
                                                       size: NSSize(width: 1, height: 1)),
                                    of: contentView, preferredEdge: .minY)
                            }
                        }
                        .help("Share this source file")
                        Button("Reveal in Finder", systemImage: "folder") {
                            Task { await fileProvider.revealSourceInFinder(id: file.id) }
                        }
                        .help("Reveal this source file in Finder")
                    }
                    if isMarkdownEditable {
                        Button {
                            isOutlineExpanded.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help("Toggle Outline")
                    }
                }
            }

            if isThisFileExtracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Extracting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
        .padding(PageEditorMetrics.contentInset)
    }

    // MARK: - Zotero origin

    /// A small provenance row shown only for files ingested from a Zotero library
    /// item: a "Zotero" tag with the item's title, and a "View in Zotero" link
    /// that opens the item via the `zotero://select` URI scheme in the Zotero
    /// desktop app. Files ingested via drag-drop / URL / folder import show
    /// nothing here — empty keeps the header clean rather than adding a neutral
    /// "Imported" tag.
    @ViewBuilder
    private func zoteroOriginRow(key: String) -> some View {
        HStack(spacing: 8) {
            Label {
                Text("Zotero")
                    .font(.callout)
                    .fontWeight(.medium)
            } icon: {
                Image(systemName: "books.vertical")
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)

            if let title = file.zoteroItemTitle, !title.isEmpty {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let url = zoteroItemURL(itemKey: key) {
                Spacer(minLength: 0)
                Button("View in Zotero", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }

    /// Build a `zotero://select` URI that opens the item directly in the Zotero
    /// desktop app. The `select/library/items/<key>` path targets "My Library"
    /// and needs no library ID — perfect for a personal-library workflow.
    private func zoteroItemURL(itemKey: String) -> URL? {
        guard !itemKey.isEmpty else { return nil }
        return URL(string: "zotero://select/library/items/\(itemKey)")
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if showTabs {
            tabbedContent
        } else if isPDF {
            pdfOnlyContent
        } else if isMarkdownNative {
            markdownContent
        } else {
            binaryFallback
        }
    }

    // MARK: View mode picker

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(FileContentTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.callout)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selectedTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, 6)
    }

    // MARK: Split Markdown ⇄ PDF

    @ViewBuilder
    private var splitContent: some View {
        HSplitView {
            markdownContent
            pdfView
        }
    }

    // MARK: Content by selected tab

    @ViewBuilder
    private var tabbedContent: some View {
        switch selectedTab {
        case .markdown:
            markdownContent
        case .pdf:
            pdfView
        case .split:
            splitContent
        }
    }

    // MARK: Markdown reader / editor

    @ViewBuilder
    private var markdownContent: some View {
        if isEditing {
            TextEditor(text: $editBuffer)
                .font(.system(size: 13 * editorZoom, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PageEditorMetrics.contentInset)
                .zoomShortcuts($editorZoom)
                .zoomScroll($editorZoom)
        } else if let head = headVersion {
            // The web reader is the only reader — it handles all sizes (its
            // windowed layout is faster than the native reader even on small
            // docs, so the size threshold that once gated web-vs-native is gone).
            WikiReaderView(markdown: head.content,
                            currentSelection: store.selection,
                            store: store,
                            findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                .zoomShortcuts($readerZoom)
                .zoomScroll($readerZoom)
        } else {
            ContentUnavailableView {
                Label("No Processed Markdown", systemImage: "doc.plaintext")
            } description: {
                Text("This file has no extracted or processed markdown yet.")
            }
        }
    }

    // MARK: PDF-only (no extraction yet)

    private var pdfOnlyContent: some View {
        pdfView
    }

    private var pdfView: some View {
        Group {
            if let data = store.sourceBytes(id: file.id) {
                PDFViewWrapper(data: data, highlightQuote: pdfQuote)
            } else {
                ContentUnavailableView {
                    Label("Cannot Load PDF", systemImage: "doc.richtext")
                } description: {
                    Text("The source bytes for this file could not be read.")
                }
            }
        }
    }

    // MARK: Extract button


    /// Extraction progress is shown in the transcript sidebar's PDF Conversion
    /// box — the detail view keeps only a minimal Extracting… spinner in the
    /// header. All log output writes to `launcher.extractionLog`.
    private func runExtraction() async {
        isExtracting = true
        launcher.isExtracting = true
        launcher.extractionPID = nil
        launcher.extractionLog = ""
        defer {
            isExtracting = false
            launcher.isExtracting = false
            launcher.extractionPID = nil
        }
        let acquired = await launcher.awaitExtractionSlot()
        guard acquired, !Task.isCancelled else {
            if acquired { launcher.releaseExtractionSlot() }
            launcher.extractionLog = "Extraction cancelled."
            return
        }
        launcher.extractingSourceIDs.insert(file.id)
        defer {
            launcher.extractingSourceIDs.remove(file.id)
            launcher.releaseExtractionSlot()
        }
        let extractor = extractionCoordinator.current()
        switch await extractor.readiness() {
        case .ready:
            guard let data = store.sourceBytes(id: file.id) else {
                launcher.extractionLog = "Could not read source bytes."
                return
            }
            do {
                // PID-less protocol: the local backend reports its pid via
                // onProgress; remote/model backends have none.
                let markdown = try await extractor.convert(
                    pdfData: data,
                    filename: file.filename,
                    onProgress: { line in
                        Task { @MainActor in launcher.extractionLog.append(line) }
                    })
                if let version = store.seedPdfMarkdown(for: file.id, content: markdown) {
                    headVersion = version
                    launcher.extractionLog = "Markdown extracted — \(markdown.count) chars."
                }
            } catch {
                if Task.isCancelled {
                    launcher.extractionLog = "Extraction cancelled."
                } else {
                    launcher.extractionLog = "Extraction failed: \(error.localizedDescription)"
                }
            }
        case .needsSetup(let message), .notInstalled(let message):
            launcher.extractionLog = message
        }
    }

    // MARK: Binary fallback

    private var binaryFallback: some View {
        ContentUnavailableView {
            Label("Raw Source", systemImage: symbol)
        } description: {
            Text("This file is stored verbatim in the wiki. Ingesting asks the agent to read it, create or update wiki pages, refresh index.md, and append log.md.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Edit helpers

    private func commitEdit() {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { isEditing = false; return }
        if let current = headVersion, trimmed == current.content {
            isEditing = false
            return
        }
        if let version = store.saveProcessedMarkdown(for: file.id, content: trimmed) {
            headVersion = version
        }
        isEditing = false
    }

    private func flushEditIfDirty() {
        guard isEditing else { return }
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = headVersion, !trimmed.isEmpty, trimmed != current.content {
            if let version = store.saveProcessedMarkdown(for: file.id, content: trimmed) {
                headVersion = version
            }
        }
        isEditing = false
    }

    // MARK: - Shared sub-views

    @ViewBuilder
    private var statusLabel: some View {
        if isIngesting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Ingesting…")
            }
            .foregroundStyle(.orange)
        } else {
            Label(
                hasBeenIngested ? "Processed" : "Ready to ingest",
                systemImage: hasBeenIngested ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(hasBeenIngested ? .green : .secondary)
        }
    }

    private var symbol: String {
        if file.mimeType == "application/pdf" { return "doc.richtext" }
        if let mime = file.mimeType, mime.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }

    // MARK: - Find bar

    @ViewBuilder
    private var findBarOverlay: some View {
        if findModel.isShowing {
            VStack(spacing: 0) {
                FindBarView(model: findModel)
                Divider()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var findShortcutButton: some View {
        Button("") { findModel.toggle() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).allowsHitTesting(false)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Human label for a `SourceMarkdownVersion.origin` value, describing how
    /// the currently-displayed markdown version came to exist. `nil` for
    /// "source" (the as-ingested seed version of a native markdown file,
    /// which the added-date row above already covers) so the row is omitted.
    private static func markdownOriginLabel(for origin: String) -> String? {
        switch origin {
        case "extraction": return "Converted"
        case "user": return "Edited"
        case "revert": return "Reverted"
        default: return nil
        }
    }
}

/// Keys the PDF-only anchor consume task so it re-fires on repeat quote clicks
/// to the same un-extracted PDF (same file, bumped anchor version).
private struct PDFTaskKey: Hashable {
    let sourceID: PageID
    let anchorVersion: Int
}
