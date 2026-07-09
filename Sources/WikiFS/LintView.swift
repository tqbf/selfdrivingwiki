import SwiftUI
import WikiFSCore

/// Sidebar-accessible lint surface. Runs the Lint operation against the current
/// wiki and displays the agent transcript.
struct LintView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                Text("Lint")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Health-check the wiki for stale content, broken links, and inconsistencies. The agent reviews all pages and writes findings to the activity log.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Run Lint", systemImage: "checkmark.shield") {
                    Task {
                        await AgentOperationRunner.runLint(
                            launcher: launcher,
                            store: store,
                            manager: manager,
                            fileProvider: fileProvider)
                    }
                }
                .disabled(launcher.isRunning)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(PageEditorMetrics.contentInset)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            AgentActivitySidebar(launcher: launcher, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
