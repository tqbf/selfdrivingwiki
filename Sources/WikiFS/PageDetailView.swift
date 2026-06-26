import SwiftUI
import WikiFSCore

/// Unified page surface. The header (title, date, action buttons) stays fixed
/// regardless of mode. The content area below the divider swaps between rendered
/// markdown and the monospaced source editor. Save/Cancel appear inline in the
/// header — same position as the Edit / Copy Path buttons they replace.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @State private var isEditing = false
    @AppStorage("editor.zoom") private var editorZoom = Double(ZoomScale.defaultScale)
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)

    // Find bar state.
    @State private var findModel = FindModel()
    @State private var findVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, same layout in both modes.
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                Text(displayTitle)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    if let date = pageUpdatedAt {
                        Text(date, style: .date)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if isEditing {
                        Button("Save Changes", systemImage: "checkmark.circle") {
                            commitEdit()
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(store.isAgentRunning
                                  || store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel", systemImage: "xmark.circle") {
                            isEditing = false
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        Button(store.isAgentRunning ? "Agent updating wiki…" : "Edit",
                               systemImage: "pencil") { isEditing = true }
                            .disabled(store.isAgentRunning)
                            .help(store.isAgentRunning
                                  ? "Editing is paused while the agent is updating the wiki"
                                  : "Edit this page manually")
                        if let path = pageMountPath {
                            Button("Copy Path", systemImage: "terminal") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(path, forType: .string)
                            }
                            .help("Copy the Unix path of this page on the mounted filesystem")
                        }
                    }
                }
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            // Non-blocking hints: a saved draft with a broken ```mermaid block
            // and/or cosmetic markdown issues. Surfaced on save; clear once the
            // issues are fixed and re-saved. Combined into a single banner when
            // both are present to avoid stacked notification noise.
            saveWarningBanner

            // Content — swaps between reader and editor, header stays put.
            if isEditing {
                TextEditor(text: $store.draftBody)
                    .font(.system(size: 13 * editorZoom, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, PageEditorMetrics.contentInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: PageEditorMetrics.editorMinHeight)
                    .onChange(of: store.draftBody) { store.bodyChanged() }
                    .zoomShortcuts($editorZoom)
                    .zoomScroll($editorZoom)
            } else {
                WikiReaderView(markdown: readerMarkdown,
                                currentSelection: store.selection,
                                store: store,
                                fileProvider: fileProvider,
                                findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: PageEditorMetrics.previewMinHeight)
                    .zoomShortcuts($readerZoom)
                    .zoomScroll($readerZoom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
        .onChange(of: store.selection) {
            isEditing = false
        }
        .onChange(of: store.isAgentRunning) { _, isRunning in
            if isRunning { isEditing = false }
        }
        .background { findShortcutButton }
        .overlay(alignment: .top) { findBarOverlay }
        .onChange(of: store.selection) { findModel.dismiss() }
        .onChange(of: readerMarkdown) { _, newMarkdown in
            findModel.content = newMarkdown
            findModel.search()
        }
        .onChange(of: findModel.isShowing) { _, showing in
            if showing {
                findModel.content = readerMarkdown
                findModel.search()
            }
        }
        .onChange(of: findModel.currentMatchIndex) { _, _ in
            guard findModel.currentMatchIndex > 0 else { return }
            findVersion &+= 1
        }
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

    // MARK: - Computed

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

    private var displayTitle: String {
        store.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled" : store.draftTitle
    }

    private var readerMarkdown: String {
        let trimmedTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = store.draftBody.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return store.draftBody }
        let firstHeading = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstHeading == "# \(trimmedTitle)" else { return store.draftBody }
        let remainingLines = lines.dropFirst()
        let withoutDuplicateHeading = remainingLines
            .drop(while: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .joined(separator: "\n")
        return withoutDuplicateHeading
    }

    private var pageUpdatedAt: Date? {
        guard let selection = store.selection,
              case .page(let id) = selection else { return nil }
        return store.summaries.first(where: { $0.id == id })?.updatedAt
    }

    private var pageMountPath: String? {
        guard let selection = store.selection,
              case .page(let id) = selection else { return nil }
        guard let title = store.summaries.first(where: { $0.id == id })?.title,
              let root = fileProvider.path else { return nil }
        let leaf = FilenameEscaping.byTitleFilename(title: title, pageID: id.rawValue)
        return "\(root)/pages/by-title/\(leaf)"
    }

    // MARK: - Subviews

    @ViewBuilder private var saveWarningBanner: some View {
        if store.mermaidSaveWarning != nil || store.markdownSaveWarning != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let mermaid = store.mermaidSaveWarning {
                    Text(mermaid)
                        .foregroundStyle(.orange)
                }
                if let md = store.markdownSaveWarning {
                    markdownSection(md)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func markdownSection(_ md: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Markdown formatting (informational — page saved as-is):\n\(md)")
                .foregroundStyle(.orange.opacity(0.8))
            Spacer(minLength: 4)
            // The button only appears when markdownSaveWarning is non-nil, which
            // only happens when the linter IS loaded — so fixMarkdownInDraft()
            // will always have a linter to call. No separate nil guard needed.
            Button("Fix", systemImage: "wand.and.stars") {
                store.fixMarkdownInDraft()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Auto-fix cosmetic markdown issues (trailing whitespace, blank-line spacing, etc.)")
        }
    }

    // MARK: - Actions

    private func commitEdit() {
        store.flushPendingSave()
        isEditing = false
    }

}
