import SwiftUI
import WikiFSCore

/// The main content pane for the current selection. Kept separate from
/// `ContentView` so the app shell owns layout/chrome while this view owns the
/// selected document/source surface.
struct WikiDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher       // ingest launcher
    @Bindable var queryLauncher: AgentLauncher   // query-only launcher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    let extractionCoordinator: ExtractionCoordinator
    let runIngest: (PageID) -> Void
    @Binding var showingImportMarkdown: Bool
    @Binding var showingAddFromZotero: Bool
    let isZoteroConfigured: Bool
    @Environment(\.addURLHandler) private var addURLHandler

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
                        addURLHandler?("")
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
                launcher: queryLauncher,
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
        case .source(let id):
            if let file = store.sources.first(where: { $0.id == id }) {
                SourceDetailView(
                    file: file,
                    hasBeenIngested: store.isSourceIngested(file),
                    isIngesting: launcher.ingestingSourceIDs.contains(file.id),
                    isRunning: launcher.isRunning,
                    isAnySourceIngesting: !launcher.ingestingSourceIDs.isEmpty,
                    // This file is mid-extraction via EITHER path (the ingest-path
                    // pdf2md step or the standalone runExtraction) — both insert
                    // into `extractingSourceIDs`, so this is now extraction-phase
                    // driven rather than the old `isExtracting &&
                    // ingestingSourceIDs.contains` overload.
                    isThisFileExtracting: launcher.extractingSourceIDs.contains(file.id),
                    // True when the edit lock is held but NO ingest is in flight —
                    // the query agent has "Allow wiki edits" checked and owns the lock.
                    isEditLockedExternally: store.isAgentRunning && launcher.ingestingSourceIDs.isEmpty,
                    runIngest: runIngest,
                    launcher: launcher,
                    extractionCoordinator: extractionCoordinator,
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
