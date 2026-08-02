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
    /// Owns the tracked repositories' clones, fetch loop, and update queue.
    let tracker: RepoTracker
    @State private var renameTarget: WikiPageSummary?
    @State private var renameText: String = ""
    /// Drives the "Add from URL…" sheet (fetch a URL → ingested file).
    @State private var showingAddFromURL = false
    /// Drives the "Track a Repository" sheet (clone a git remote → tracked repo).
    @State private var showingAddRepository = false

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
                        Button("Add from URL…", systemImage: "link.badge.plus") {
                            showingAddFromURL = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Fetch a web page or PDF by URL and ingest it")
                    }
                }
            }
            // Repositories are oldest-first (the order they were added), so the
            // list doesn't reshuffle every time one syncs.
            if !store.repos.isEmpty {
                Section {
                    ForEach(store.repos) { repo in
                        RepoRow(
                            repo: repo,
                            activity: tracker.activity[repo.id],
                            onFetch: { Task { await tracker.fetch(repo) } },
                            onRemove: { tracker.removeRepo(repo) }
                        )
                        .tag(WikiSelection.repo(repo.id))
                    }
                } header: {
                    HStack(spacing: 10) {
                        Text("Repositories")
                        Spacer()
                        // Checking is explicit: nothing fetches on a timer, so
                        // this is how a repo's "Changes" badge gets refreshed.
                        Button("Check for New Commits", systemImage: "arrow.clockwise") {
                            Task { await tracker.fetchAll() }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(tracker.isBusy)
                        .help("Fetch every tracked repository and show which ones have moved")
                        Button("Track a Repository…", systemImage: "plus") {
                            showingAddRepository = true
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Clone a git repository so the wiki can be kept up to date with it")
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
            // One "add a source" menu rather than a button per source kind: the
            // toolbar doubles as the window drag area and should stay sparse, and
            // both sections' inline headers only exist once they have content —
            // so this is the entry point when the wiki is empty.
            ToolbarItem {
                Menu {
                    Button("Add from URL…", systemImage: "link.badge.plus") {
                        showingAddFromURL = true
                    }
                    Button("Track a Repository…", systemImage: "arrow.triangle.branch") {
                        showingAddRepository = true
                    }
                } label: {
                    Label("Add Source", systemImage: "tray.and.arrow.down")
                }
                .help("Ingest a web page or PDF by URL, or track a git repository")
            }
            ToolbarItem {
                Button("New Page", systemImage: "plus") { store.newPage() }
            }
        }
        .sheet(isPresented: $showingAddFromURL) {
            AddFromURLSheet(store: store)
        }
        .sheet(isPresented: $showingAddRepository) {
            AddRepositorySheet(tracker: tracker)
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
