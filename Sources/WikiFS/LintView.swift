import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Sidebar-accessible lint surface. Runs the Lint operation against the current
/// wiki and displays the agent transcript.
struct LintView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: WikiSession
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
                            wikiID: session.wikiID,
                            changeSignaler: fileProvider,
                            wikictlDirectory: HelpersLocation.wikictlDirectory)
                    }
                }
                .disabled(launcher.isRunning)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(PageEditorMetrics.contentInset)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            // Inline agent transcript (sidebar removed in Phase 7).
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("Agent Activity", systemImage: "sparkles")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    if launcher.isRunning {
                        Button("Stop Agent", systemImage: "stop.fill") {
                            launcher.stopAgent()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Stop the agent run")
                    }
                }
                AgentActivityView(
                    launcher: launcher,
                    showsInternals: false,
                    onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
            }
            .padding(PageEditorMetrics.contentInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
