import SwiftUI
import WikiFSCore

/// Read-only in-app view of `log.md`, the append-only operation history where
/// agents record ingests, queries, lints, and their notes. Rendered two ways:
/// as a full-width tab (address-bar navigation) and, with `compact`, inside
/// the trailing change-log sidebar toggled from the window toolbar.
struct ChangeLogDetailView: View {
    @Bindable var store: WikiStoreModel
    /// Sidebar mode: smaller title, tighter insets, and a close affordance —
    /// sized for the trailing panel rather than a full-width tab.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: compact ? 2 : 6) {
                    Text("Change Log")
                        .font(compact ? .headline : .largeTitle)
                        .bold()
                        .textSelection(.enabled)
                    Text("Query answers, ingest notes, and lint results from log.md.")
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                }
                if compact {
                    Spacer()
                    Button {
                        store.isChangeLogSidebarVisible = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide Change Log")
                }
            }
            .frame(maxWidth: compact ? .infinity : PageEditorMetrics.readableContentWidth,
                   alignment: .leading)
            .padding(.horizontal, compact ? 12 : PageEditorMetrics.contentInset)
            .padding(.top, compact ? 12 : PageEditorMetrics.contentInset)
            .padding(.bottom, compact ? 10 : PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            if logMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No Log Entries", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Agent runs will append their notes here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WikiReaderView(markdown: logMarkdown,
                                currentSelection: store.selection,
                                store: store)
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
