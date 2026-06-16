import SwiftUI
import WikiFSCore

/// Reader-first surface for the selected page. Manual editing is an explicit mode:
/// the default state renders the page as an article, while Edit reveals the source
/// editor and keeps the existing autosave buffers intact.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunBanner(isVisible: store.isAgentRunning)

            if isEditing {
                PageEditorView(store: store)
            } else {
                PageReaderView(
                    store: store,
                    isRunning: launcher.isRunning,
                    onQuery: runQuery
                )
            }
        }
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done Editing" : "Edit Page", systemImage: isEditing ? "checkmark" : "pencil") {
                    toggleEditing()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(store.isAgentRunning)
                .help(isEditing ? "Return to the page reader" : "Edit this page manually")
            }
        }
        .onChange(of: store.selection) {
            isEditing = false
        }
        .onChange(of: store.isAgentRunning) { _, isRunning in
            if isRunning {
                isEditing = false
            }
        }
    }

    private func toggleEditing() {
        if isEditing {
            store.flushPendingSave()
        }
        isEditing.toggle()
    }

    private func runQuery(_ question: String) {
        Task {
            await AgentOperationRunner.runQuery(
                question: question,
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
    }
}
