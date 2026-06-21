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
    @Binding var showingAddFromURL: Bool
    @Binding var showingImportMarkdown: Bool
    @Binding var showingAddFromZotero: Bool
    let isZoteroConfigured: Bool

    var body: some View {
        switch store.selection {
        case .none:
            ContentUnavailableView {
                Label("No Page Selected", systemImage: "doc.text")
            } description: {
                Text("Select a page from the sidebar, create a new one, or add source material.")
            } actions: {
                VStack(spacing: 8) {
                    Button("New Page", systemImage: "plus") { store.newPage() }
                    Button("Add from URL…", systemImage: "link.badge.plus") {
                        showingAddFromURL = true
                    }
                    Button("Import Markdown Folder…", systemImage: "doc.badge.plus") {
                        showingImportMarkdown = true
                    }
                    if isZoteroConfigured {
                        Button("Add from Zotero…", systemImage: "books.vertical") {
                            showingAddFromZotero = true
                        }
                    }
                }
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
        case .lint:
            LintView(
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
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
                    isIngesting: launcher.ingestingFileIDs.contains(file.id),
                    isRunning: launcher.isRunning,
                    isAnyFileIngesting: !launcher.ingestingFileIDs.isEmpty,
                    // This file is mid-extraction via EITHER path (the ingest-path
                    // pdf2md step or the standalone runExtraction) — both insert
                    // into `extractingFileIDs`, so this is now extraction-phase
                    // driven rather than the old `isExtracting &&
                    // ingestingFileIDs.contains` overload.
                    isThisFileExtracting: launcher.extractingFileIDs.contains(file.id),
                    runIngest: runIngest,
                    launcher: launcher,
                    store: store
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
