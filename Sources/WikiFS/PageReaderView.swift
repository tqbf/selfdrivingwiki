import SwiftUI
import WikiFSCore

/// Article-style page reader. The app's normal mode is for reading what the
/// agent maintains; manual source editing lives behind PageDetailView's Edit action.
struct PageReaderView: View {
    @Bindable var store: WikiStoreModel
    let updatedAt: Date?
    let mountPath: String?
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                Text(displayTitle)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    if let date = updatedAt {
                        Text(date, style: .date)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Edit", systemImage: "pencil") { onEdit() }
                        .disabled(store.isAgentRunning)
                        .help("Edit this page manually")
                    if let path = mountPath {
                        Button("Copy Path", systemImage: "terminal") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        }
                        .help("Copy the Unix path of this page on the mounted filesystem")
                    }
                }
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            MarkdownPreview(store: store, markdown: readerMarkdown)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PageEditorMetrics.previewMinHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var displayTitle: String {
        store.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : store.draftTitle
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
}
