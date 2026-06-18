import SwiftUI
import WikiFSCore

/// Page list. `List(selection:)` bound straight to the model's selection; rows
/// are `WikiPageSummary` (Identifiable, so no explicit `id:`). Both a
/// `.contextMenu` and `.swipeActions` expose Rename/Delete (§4.1 / §7.4), and
/// the modern inset + hidden-background list look matches Notes/Mail (§4.2).
struct SidebarView: View {
    @Bindable var store: WikiStoreModel
    /// The multi-wiki manager — backs the switcher header at the top of the list.
    @Bindable var manager: WikiManager
    /// Used to open an ingested file in its default app via its user-visible URL.
    let fileProvider: FileProviderSpike
    @State private var renameTarget: WikiPageSummary?
    @State private var renameText: String = ""
    /// Drives the "Add from URL…" sheet (fetch a URL → ingested file).
    @State private var showingAddFromURL = false
    /// Drives the "Add from Zotero…" sheet (browse the library → ingested file).
    @State private var showingAddFromZotero = false

    var body: some View {
        List(selection: $store.selection) {
            // The wiki switcher — the top-level container switch (which knowledge
            // base am I in). No `.tag`, so it never feeds the page selection.
            WikiSwitcher(manager: manager)
                .listRowSeparator(.hidden)

            Section("Tools") {
                SidebarModeRow(
                    title: "Query",
                    subtitle: "Ask or update",
                    systemImage: "bubble.left.and.text.bubble.right"
                )
                .tag(WikiSelection.query)
                .help("Ask questions and decide whether Claude should update the wiki")
            }

            Section("System") {
                SidebarModeRow(
                    title: "Activity",
                    subtitle: "Operation log",
                    systemImage: "clock.arrow.circlepath"
                )
                .tag(WikiSelection.changeLog)
                .help("Operation history, projected read-only as log.md")

                SidebarModeRow(
                    title: "Instructions",
                    subtitle: "Agent prompt",
                    systemImage: "sparkles"
                )
                .tag(WikiSelection.systemPrompt)
                .help("Agent instructions, projected read-only as CLAUDE.md and AGENTS.md")
            }

            Section("Pages") {
                ForEach(store.summaries) { summary in
                    SidebarPageRow(summary: summary)
                        .tag(WikiSelection.page(summary.id))
                        .contextMenu {
                            Button("Rename") { beginRename(summary) }
                            Button("Delete", role: .destructive) { store.delete(summary.id) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { store.delete(summary.id) }
                        }
                }
            }
            // Files are most-recently-added first (the store orders by created_at
            // DESC). Selecting one opens a detail pane with direct ingest controls.
            if !store.ingestedFiles.isEmpty {
                Section {
                    ForEach(store.ingestedFiles) { file in
                        IngestedFileRow(
                            file: file,
                            hasBeenIngested: store.hasIngestedFile(file),
                            onOpen: { Task { await fileProvider.openIngestedFile(id: file.id) } },
                            onRemove: { store.deleteIngestedFile(file.id) }
                        )
                        .tag(WikiSelection.ingestedFile(file.id))
                    }
                } header: {
                    HStack {
                        Text("Files")
                        Spacer()
                        if isZoteroConfigured {
                            Button("Add from Zotero…", systemImage: "books.vertical") {
                                showingAddFromZotero = true
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Browse your Zotero library and ingest a PDF or Markdown attachment")
                        }
                        Button("Add from URL…", systemImage: "link.badge.plus") {
                            showingAddFromURL = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Fetch a web page or PDF by URL and ingest it")
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .navigationTitle(activeWikiName)
        .navigationSplitViewColumnWidth(
            min: PageEditorMetrics.sidebarMinWidth,
            ideal: PageEditorMetrics.sidebarIdealWidth
        )
        .toolbar {
            if isZoteroConfigured {
                ToolbarItem {
                    Button("Add from Zotero…", systemImage: "books.vertical") {
                        showingAddFromZotero = true
                    }
                    .help("Browse your Zotero library and ingest a PDF or Markdown attachment")
                }
            }
            ToolbarItem {
                Button("Add from URL…", systemImage: "link.badge.plus") {
                    showingAddFromURL = true
                }
                .help("Fetch a web page or PDF by URL and ingest it into this wiki")
            }
            ToolbarItem {
                Button("New Page", systemImage: "plus") { store.newPage() }
            }
        }
        .sheet(isPresented: $showingAddFromURL) {
            AddFromURLSheet(store: store)
        }
        .sheet(isPresented: $showingAddFromZotero) {
            AddFromZoteroSheet(store: store, containerDirectory: zoteroContainerDirectory)
        }
        .alert("Rename Page", isPresented: renamePresented) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    store.rename(target.id, to: renameText)
                }
                renameTarget = nil
            }
        }
    }

    /// The App Group container — same fallback `WikiFSApp.init()` uses, resolved
    /// independently here rather than threaded through `ContentView`/`RootView`
    /// (existing precedent: `WikiResolver` does the same in `WikiCtlCore`).
    private var zoteroContainerDirectory: URL {
        (try? DatabaseLocation.appGroupContainerDirectory()) ?? FileManager.default.temporaryDirectory
    }

    /// Whether Settings has a library ID AND an API key — both required before
    /// the picker can do anything useful.
    private var isZoteroConfigured: Bool {
        ZoteroConfig.load(from: zoteroContainerDirectory).isConfigured
            && KeychainZoteroCredentialStore().apiKey() != nil
    }

    /// The active wiki's display name for the window title (falls back to the app
    /// name when no wiki is selected yet).
    private var activeWikiName: String {
        guard let id = manager.activeWikiID else { return "Self Driving Wiki" }
        return manager.wikis.first { $0.id == id }?.displayName ?? "Self Driving Wiki"
    }

    private func beginRename(_ summary: WikiPageSummary) {
        renameText = summary.title
        renameTarget = summary
    }

    /// Drive the rename alert off `renameTarget != nil` without a manual
    /// `Binding(get:set:)` for the value itself (we only need a Bool here).
    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}
