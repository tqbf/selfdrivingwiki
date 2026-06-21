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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunBanner(isVisible: store.isAgentRunning)

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
                        Button("Edit", systemImage: "pencil") { isEditing = true }
                            .disabled(store.isAgentRunning)
                            .help("Edit this page manually")
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
                MarkdownPreview(store: store, markdown: readerMarkdown,
                                currentSelection: store.selection,
                                fileProvider: fileProvider)
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
    }

    // MARK: - Computed

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

    // MARK: - Actions

    private func commitEdit() {
        store.flushPendingSave()
        isEditing = false
    }

}
