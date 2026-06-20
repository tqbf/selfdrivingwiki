import SwiftUI
import WikiFSCore

/// Detail pane for one ingested source file. Shows metadata header + inline
/// content (markdown render, inline PDF, or tabbed Markdown⇄PDF when extraction
/// output exists). Cmd-E flips between reader and editor for processed markdown;
/// source bytes are never modified.
struct IngestedFileDetailView: View {
    let file: IngestedFileSummary
    let hasBeenIngested: Bool
    let isIngesting: Bool
    let isRunning: Bool
    let runIngest: (PageID) -> Void
    @Bindable var store: WikiStoreModel

    @State private var headVersion: FileMarkdownVersion?
    @State private var isEditing = false
    @State private var editBuffer = ""
    @State private var isExtracting = false
    @State private var extractionLog = ""
    @State private var selectedTab = FileContentTab.markdown

    private enum FileContentTab: String, CaseIterable {
        case markdown = "Markdown"
        case pdf = "PDF"
        case split = "Split"
    }

    // MARK: - Computed

    private var isMarkdownNative: Bool {
        file.ext == "md" || file.ext == "markdown" || file.ext == "txt"
    }

    private var isPDF: Bool { file.ext == "pdf" }

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
            flushEditIfDirty()
            isEditing = false
            headVersion = nil
            selectedTab = .markdown
            extractionLog = ""
        }
        .task(id: file.id) { headVersion = store.processedMarkdownHead(for: file) }
        .onChange(of: store.selection) { flushEditIfDirty(); isEditing = false }
        .onChange(of: store.isAgentRunning) {
            if $1 { flushEditIfDirty(); isEditing = false }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("Done Editing", systemImage: "checkmark") { commitEdit() }
                        .keyboardShortcut("e", modifiers: .command)
                        .help("Save changes and return to reader")
                } else if isMarkdownEditable {
                    Button("Edit", systemImage: "pencil") {
                        editBuffer = headVersion?.content ?? ""
                        isEditing = true
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(store.isAgentRunning)
                    .help("Edit processed markdown")
                }
            }
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

            HStack(spacing: 10) {
                Button(isIngesting ? "Ingesting…" : "Ingest into Wiki",
                       systemImage: "text.badge.plus") {
                    DebugLog.ingest("IngestedFileDetailView: Ingest tapped — id=\(file.id.rawValue)")
                    runIngest(file.id)
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isRunning || isIngesting)
                if isPDF, !hasMarkdown {
                    Button(isExtracting ? "Extracting…" : "Extract Markdown",
                           systemImage: "doc.plaintext") {
                        Task { await runExtraction() }
                    }
                    .disabled(isExtracting || isRunning)
                }
                if isMarkdownEditable {
                    Button("Edit", systemImage: "pencil") {
                        editBuffer = headVersion?.content ?? ""
                        isEditing = true
                    }
                    .disabled(isRunning || isEditing)
                }
            }

            if isExtracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(extractionLog.isEmpty ? "Extracting…" : extractionLog)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !extractionLog.isEmpty {
                Text(extractionLog)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        }
        .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
        .padding(PageEditorMetrics.contentInset)
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
            VStack(spacing: 0) {
                TextEditor(text: $editBuffer)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(PageEditorMetrics.contentInset)

                HStack(spacing: 10) {
                    Button("Save Changes", systemImage: "checkmark.circle") {
                        commitEdit()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(editBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (headVersion?.content == editBuffer))

                    Button("Cancel", systemImage: "xmark.circle") {
                        isEditing = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, PageEditorMetrics.contentInset)
                .padding(.bottom, PageEditorMetrics.sectionSpacing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
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
            if let data = store.ingestedSourceBytes(id: file.id) {
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


    private func runExtraction() async {
        isExtracting = true
        extractionLog = ""
        defer { isExtracting = false }
        guard await PdfExtractionService.checkReady() else {
            extractionLog = "PDF extraction not available — pdf2md is not ready."
            return
        }
        guard let data = store.ingestedSourceBytes(id: file.id) else {
            extractionLog = "Could not read source bytes."
            return
        }
        do {
            let markdown = try await PdfExtractionService.convert(
                pdfData: data, filename: file.filename)
            if let version = store.seedPdfMarkdown(fileID: file.id, content: markdown) {
                headVersion = version
                extractionLog = "Markdown extracted — \(markdown.count) chars."
            }
        } catch {
            extractionLog = "Extraction failed: \(error.localizedDescription)"
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
                hasBeenIngested ? "Ingested" : "Ready to ingest",
                systemImage: hasBeenIngested ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(hasBeenIngested ? .green : .secondary)
        }
    }

    private var symbol: String {
        switch file.ext {
        case "pdf": "doc.richtext"
        case "txt", "md", "markdown": "doc.plaintext"
        default: "doc"
        }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
