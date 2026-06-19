import SwiftUI
import WikiFSCore

/// The main content pane for the current selection. Kept separate from
/// `ContentView` so the app shell owns layout/chrome while this view owns the
/// selected document/source surface.
struct WikiDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    let runIngest: (PageID) -> Void

    var body: some View {
        switch store.selection {
        case .none:
            ContentUnavailableView {
                Label("No Page Selected", systemImage: "doc.text")
            } description: {
                Text("Select a page from the sidebar, or create a new one.")
            } actions: {
                Button("New Page", systemImage: "plus") { store.newPage() }
            }
        case .query:
            QueryConversationView(
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider
            )
        case .systemPrompt:
            SystemPromptDetailView(store: store)
        case .changeLog:
            ChangeLogDetailView(store: store)
        case .page:
            PageDetailView(
                store: store,
                launcher: launcher,
                manager: manager,
                fileProvider: fileProvider)
        case .ingestedFile(let id):
            if let file = store.ingestedFiles.first(where: { $0.id == id }) {
                IngestedFileDetailView(
                    file: file,
                    hasBeenIngested: store.hasIngestedFile(file),
                    isIngesting: launcher.ingestingFileID == file.id,
                    isRunning: launcher.isRunning,
                    fileProvider: fileProvider,
                    onOpen: { Task { await fileProvider.openIngestedFile(id: file.id) } },
                    runIngest: runIngest
                )
            } else {
                ContentUnavailableView {
                    Label("File Missing", systemImage: "doc.badge.questionmark")
                } description: {
                    Text("This ingested file is no longer available.")
                }
            }
        }
    }
}
