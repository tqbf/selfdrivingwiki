import SwiftUI
import WikiFSCore

/// Detail pane for one ingested source file. Shows metadata header + inline
/// content (markdown render, inline PDF, or tabbed Markdown⇄PDF when extraction
/// output exists). Cmd-E flips between reader and editor for processed markdown;
/// source bytes are never modified.
struct IngestedFileDetailView: View {
    let file: SourceSummary
    let hasBeenIngested: Bool
    let isIngesting: Bool
    let isRunning: Bool
    /// `true` when any file (not necessarily this one) is mid-ingest — covers the
    /// PDF-conversion phase before the agent process starts, when `isRunning` is
    /// still `false`.
    let isAnyFileIngesting: Bool
    /// `true` when THIS file is mid-extraction via the ingest path (pdf2md running
    /// during an ingest of this file, before the agent spawns). Disables the
    /// standalone "Extract Markdown" button for this file only — pdf2md is safe to
    /// overlap with a claude run, so a query/ingest agent run does NOT disable it.
    let isThisFileExtracting: Bool
    let runIngest: (PageID) -> Void
    /// Shared launcher — used by the standalone `runExtraction` to take the
    /// extraction slot (so a standalone extract and an ingest-path extract serialize
    /// against each other) and to mirror this file's id into `extractingFileIDs`
    /// so the sidebar row labels it "Extracting…".
    let launcher: AgentLauncher
    @Bindable var store: WikiStoreModel

    @State private var headVersion: SourceMarkdownVersion?
    @State private var isEditing = false
    @State private var editBuffer = ""
    @State private var isExtracting = false
    @State private var selectedTab = FileContentTab.markdown

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
        file.filename.isEmpty ? "Untitled" : file.filename
    }

    private var alreadyIngested: Bool { hasBeenIngested }

    private var alreadyIngestedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("This document has already been ingested. Running ingest again may create duplicate pages.")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.18))
        .clipped()
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunBanner(isVisible: store.isAgentRunning)
            if alreadyIngested {
                alreadyIngestedBanner
            }
            headerSection
            if showTabs, !isEditing {
                tabPicker
            }
            Divider().opacity(PageEditorMetrics.dividerOpacity)
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { headVersion = store.processedMarkdownHead(for: file) }
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
            headVersion = nil
            selectedTab = .markdown
        }
        .task(id: file.id) { headVersion = store.processedMarkdownHead(for: file) }
        .onChange(of: store.selection) { flushEditIfDirty(); isEditing = false }
        .onChange(of: store.isAgentRunning) {
            if $1 { flushEditIfDirty(); isEditing = false }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            Label {
                Text(displayName)
                    .font(.largeTitle)
                    .bold()
                    .lineLimit(2)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                statusLabel
                Text(Self.sizeFormatter.string(fromByteCount: Int64(file.byteSize)))
                Text(file.createdAt, style: .date)
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
                } else {
                    Button(isIngesting ? "Ingesting…" : "Ingest into Wiki",
                           systemImage: "text.badge.plus") {
                        DebugLog.ingest("IngestedFileDetailView: Ingest tapped — id=\(file.id.rawValue)")
                        runIngest(file.id)
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isRunning || isIngesting || isAnyFileIngesting
                                  || isThisFileExtracting)
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
                                      && !launcher.extractingFileIDs.contains(file.id)))
                    }
                    if isMarkdownEditable {
                        Button("Edit", systemImage: "pencil") {
                            editBuffer = headVersion?.content ?? ""
                            isEditing = true
                        }
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(isRunning)
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
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PageEditorMetrics.contentInset)
        } else if let head = headVersion {
            MarkdownPreview(store: store, markdown: head.content)
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
                PDFViewWrapper(data: data)
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
        launcher.extractingFileIDs.insert(file.id)
        defer {
            launcher.extractingFileIDs.remove(file.id)
            launcher.releaseExtractionSlot()
        }
        guard await PdfExtractionService.checkReady() else {
            launcher.extractionLog = "PDF extraction not available — pdf2md is not ready."
            return
        }
        guard let data = store.sourceBytes(id: file.id) else {
            launcher.extractionLog = "Could not read source bytes."
            return
        }
        do {
            let markdown = try await PdfExtractionService.convert(
                pdfData: data,
                filename: file.filename,
                onProgress: { line in
                    Task { @MainActor in launcher.extractionLog.append(line) }
                },
                onStart: { pid in
                    Task { @MainActor in
                        launcher.extractionPID = pid
                        launcher.extractionLog.append("Started pdf2md (pid \(pid)).\n")
                    }
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

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
