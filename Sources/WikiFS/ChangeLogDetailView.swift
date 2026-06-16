import SwiftUI
import WikiFSCore

/// Read-only in-app view of `log.md`, the append-only operation history where
/// agents record ingests, queries, lints, and their notes.
struct ChangeLogDetailView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Change Log")
                    .font(.largeTitle)
                    .bold()
                    .textSelection(.enabled)
                Text("Query answers, ingest notes, and lint results from log.md.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            if logMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No Log Entries", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Agent runs will append their notes here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownPreview(store: store, markdown: logMarkdown)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: PageEditorMetrics.previewMinHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var logMarkdown: String {
        store.currentLogMarkdown()
    }
}
