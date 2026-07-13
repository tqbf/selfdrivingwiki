import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The Sources section — a native header (Add buttons, filter picker, search)
/// above an AppKit `NSTableView` (`SourcesListView`). Mirrors
/// `PagesContainerView` / `BookmarksContainerView`. Filtering and search live
/// here (SwiftUI); the AppKit list below stays dumb and just renders the
/// computed array.
struct SourcesContainerView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderSpike
    let manager: WikiManager
    let launcher: AgentLauncher
    var ingestingSourceIDs: Set<PageID> = []
    var extractingSourceIDs: Set<PageID> = []

    @Binding var showingAddFromZotero: Bool
    @Binding var showingImportMarkdown: Bool
    var onAddFromURL: () -> Void
    var isZoteroConfigured: Bool = false

    @State private var sourceFilter: SourceFilter = .all
    @State private var renameTarget: SourceSummary?
    @State private var renameText = ""
    @State private var showBatchReingestConfirmation = false
    @State private var pendingBatchIngestIDs: [PageID] = []
    @State private var pendingReingestNames: [String] = []
    /// Non-nil while the bookmark-target picker is open for a source selection.
    @State private var addToBookmarksContext: BookmarkTargetPickerContext?

    enum SourceFilter: String, CaseIterable {
        case all = "All"
        case ready = "Ready"
        case ingested = "Processed"
    }

    private var filteredSources: [SourceSummary] {
        switch sourceFilter {
        case .all: return store.sources
        case .ready: return store.sources.filter { !store.isSourceIngested($0) }
        case .ingested: return store.sources.filter { store.isSourceIngested($0) }
        }
    }

    /// Search overrides filter (mirrors the prior `SourcesSectionView` swap).
    /// Media sources (`.media`) are filtered out of both the list and search
    /// paths via `SourceSummary.isPrimary`, so they never appear in the main
    /// Sources view — they are presentation content surfaced via embeds, not the
    /// content list (graph-model §4.2).
    private var visibleSources: [SourceSummary] {
        (store.sourceSearchQuery.isEmpty ? filteredSources : store.sourceSearchResults)
            .filter { $0.isPrimary }
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcesHeader
            Divider()
            ZStack(alignment: .topLeading) {
                SourcesListView(store: store, fileProvider: fileProvider,
                                manager: manager, launcher: launcher,
                                ingestingSourceIDs: ingestingSourceIDs,
                                extractingSourceIDs: extractingSourceIDs,
                                sources: visibleSources,
                                callbacks: callbacks)
                if visibleSources.isEmpty && !store.sourceSearchQuery.isEmpty {
                    Text("No matching sources")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .alert("Rename Source", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(
            "Ingest Again?",
            isPresented: $showBatchReingestConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ingest Again", role: .destructive) {
                launcher.ingestSources(sourceIDs: pendingBatchIngestIDs,
                    store: store, wikiID: manager.activeWikiID ?? "",
                    changeSignaler: fileProvider,
                    wikictlDirectory: HelpersLocation.wikictlDirectory)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The following sources have already been ingested:\n\(pendingReingestNames.joined(separator: "\n"))\n\nRunning ingest again may create duplicate pages.")
        }
        .sheet(item: $addToBookmarksContext) { ctx in
            BookmarkTargetPickerSheet(
                store: store,
                kind: ctx.kind,
                ids: ctx.ids,
                onConfirm: { parentID in
                    for id in ctx.ids {
                        store.addSourceRef(parentID: parentID, sourceID: id)
                    }
                }
            )
        }
    }

    private var sourcesHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Sources").font(.headline).foregroundStyle(.primary)
                Spacer()
                if isZoteroConfigured {
                    headerButton(systemImage: "books.vertical", help: "Add from Zotero…") {
                        showingAddFromZotero = true
                    }
                }
                headerButton(systemImage: "link.badge.plus", help: "Add from URL…") {
                    onAddFromURL()
                }
                headerButton(systemImage: "doc.badge.plus", help: "Add File…") {
                    addFile()
                }
                headerButton(systemImage: "folder.badge.plus", help: "Add Folder…") {
                    showingImportMarkdown = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            HStack {
                Text("Show").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Filter", selection: $sourceFilter) {
                    Text("All").tag(SourceFilter.all)
                    Text("Ready").tag(SourceFilter.ready)
                    Text("Processed").tag(SourceFilter.ingested)
                }
                .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            sourceSearchBar
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
    }

    private var sourceSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.callout)
            TextField("Search sources…", text: $store.sourceSearchQuery)
                .textFieldStyle(.plain).font(.callout).disableAutocorrection(true)
            if !store.sourceSearchQuery.isEmpty {
                Button { store.sourceSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
        }
    }

    private func addFile() {
        if let url = WikiFilePanels.chooseFile(title: "Add File", prompt: "Import") {
            Task { await store.addFiles([url]) }
        }
    }

    private func headerButton(systemImage: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var callbacks: SourcesListCallbacks {
        SourcesListCallbacks(
            onOpen: { ids in
                for id in ids { store.openTab(.source(id)) }
            },
            onOpenExternal: { ids, appURL in
                for id in ids { Task { await fileProvider.openSource(id: id, with: appURL) } }
            },
            onOpenBackground: { ids in
                for id in ids { store.openTabInBackground(.source(id)) }
            },
            onShare: { ids in
                Task {
                    let urls: [URL] = await withTaskGroup(of: URL?.self) { group in
                        for id in ids {
                            group.addTask { await fileProvider.resolveSourceByNameURL(id: id) }
                        }
                        var results: [URL] = []
                        for await url in group { if let url { results.append(url) } }
                        return results
                    }
                    SidebarSharing.present(items: urls)
                }
            },
            onReveal: { id in
                Task { await fileProvider.revealSourceInFinder(id: id) }
            },
            onIngest: { ids in
                launcher.ingestSources(sourceIDs: ids, store: store,
                                       wikiID: manager.activeWikiID ?? "",
                                       changeSignaler: fileProvider,
                                       wikictlDirectory: HelpersLocation.wikictlDirectory)
            },
            onIngestNeedsConfirmation: { ids, names in
                pendingBatchIngestIDs = ids
                pendingReingestNames = names
                showBatchReingestConfirmation = true
            },
            onExtract: { items in
                Task {
                    for item in items {
                        await launcher.extractPDF(store: store, id: item.id,
                                                  filename: item.filename, data: item.data)
                    }
                }
            },
            onRename: { source in beginRename(source) },
            onDelete: { ids in
                for id in ids { store.deleteSource(id) }
            },
            onAddToBookmarks: { ids in
                addToBookmarksContext = BookmarkTargetPickerContext(kind: .sources, ids: ids)
            })
    }

    private func beginRename(_ source: SourceSummary) {
        renameText = source.displayName ?? source.filename
        renameTarget = source
    }

    private func commitRename() {
        if let target = renameTarget {
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { store.renameSource(id: target.id, to: trimmed) }
        }
        renameTarget = nil
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}
