import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSCore

/// The Sources section — a native header (Add buttons, filter picker, search)
/// above an AppKit `NSTableView` (`SourcesListView`). Mirrors
/// `PagesContainerView` / `BookmarksContainerView`. Filtering and search live
/// here (SwiftUI); the AppKit list below stays dumb and just renders the
/// computed array.
struct SourcesContainerView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderFacade
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: WikiSession
    @Environment(QueueActivityTracker.self) private var tracker
    let launcher: AgentLauncher
    let queueEngine: any QueueEngineClient
    let extractionProvider: any QueueExtractionProvider
    var ingestingSourceIDs: Set<SourceID> = []

    @Binding var showingAddFromZotero: Bool
    @Binding var showingImportMarkdown: Bool
    var onAddFromURL: () -> Void
    var isZoteroConfigured: Bool = false

    @State private var sourceFilter: SourceFilter = .all
    @State private var renameTarget: SourceSummary?
    @State private var renameText = ""
    @State private var showBatchReingestConfirmation = false
    @State private var pendingBatchIngestIDs: [SourceID] = []
    @State private var pendingReingestNames: [String] = []
    /// Non-nil while the bookmark-target picker is open for a source selection.
    @State private var addToBookmarksContext: BookmarkTargetPickerContext?
    /// Non-nil while the incoming-reference delete confirmation is open (issue #219).
    @State private var pendingDeletion: PendingSourceDeletion?

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
                                session: session, launcher: launcher,
                                ingestingSourceIDs: ingestingSourceIDs,
                                extractingSourceIDs: tracker.extractingSourceIDs,
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
                Task {
                    store.flushPendingSaves()
                    await enqueueIngestion(
                        sourceIDs: pendingBatchIngestIDs,
                        store: store,
                        wikiID: session.wikiID,
                        queueEngine: queueEngine)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The following sources have already been ingested:\n\(pendingReingestNames.joined(separator: "\n"))\n\nRunning ingest again may create duplicate pages.")
        }
        .sheet(item: $addToBookmarksContext) { ctx in
            BookmarkTargetPickerSheet(
                store: store,
                targets: ctx.targets,
                onConfirm: { parentID in
                    guard case .sources(let ids) = ctx.targets else { return }
                    for id in ids {
                        store.addSourceRef(parentID: parentID, sourceID: id)
                    }
                }
            )
        }
        .confirmationDialog(
            pendingDeletion.map { deletionDialogTitle(for: $0) } ?? "",
            isPresented: deletionDialogPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { pending in
            deletionDialogActions(for: pending)
        } message: { pending in
            Text(deletionDialogMessage(for: pending))
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
                Task {
                    store.flushPendingSaves()
                    await enqueueIngestion(
                        sourceIDs: ids,
                        store: store,
                        wikiID: session.wikiID,
                        queueEngine: queueEngine)
                }
            },
            onIngestNeedsConfirmation: { ids, names in
                pendingBatchIngestIDs = ids
                pendingReingestNames = names
                showBatchReingestConfirmation = true
            },
            onExtract: { items in
                Task {
                    for item in items {
                        do {
                            let request = QueueItemRequest(
                                queue: .extraction,
                                wikiID: session.wikiID,
                                payload: QueueItemPayload(sourceIDs: [item.id]))
                            let itemID = try await queueEngine.enqueue(request)
                            _ = try await queueEngine.waitForCompletion(of: itemID)
                        } catch {
                            DebugLog.extraction("SourcesContainerView onExtract failed for \(item.filename): \(error.localizedDescription)")
                        }
                    }
                }
            },
            onRename: { source in beginRename(source) },
            onDelete: { ids in
                requestSourceDeletion(ids)
            },
            onAddToBookmarks: { ids in
                addToBookmarksContext = BookmarkTargetPickerContext(targets: .sources(ids))
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

    // MARK: - Delete with incoming-reference warning (issue #219)

    private func requestSourceDeletion(_ ids: [SourceID]) {
        var linkingIDs: [PageID] = []
        var bookmarkFolders: Set<String> = []
        var bookmarkCount = 0
        var blockedPageIDs = Set<PageID>()
        for id in ids {
            let impact = store.deletionImpact(forSource: id)
            linkingIDs.append(contentsOf: impact.linkingPageIDs)
            bookmarkCount += impact.bookmarkLabels.count
            bookmarkFolders.formUnion(impact.bookmarkLabels)
            blockedPageIDs.formUnion(impact.provenanceBlockers.map(\.pageID))
        }
        let displayTitles = Array(Set(linkingIDs))
            .compactMap { id in store.summaries.first { $0.id == id }?.title }
            .sorted()
        let blockedTitles = blockedPageIDs
            .compactMap { id in store.summaries.first { $0.id == id }?.title }
            .sorted()

        if blockedTitles.isEmpty && displayTitles.isEmpty && bookmarkCount == 0 {
            confirmSourceDeletion(ids: ids, unlink: false)
        } else {
            pendingDeletion = PendingSourceDeletion(
                ids: ids,
                linkingPageTitles: displayTitles,
                bookmarkCount: bookmarkCount,
                bookmarkFolders: bookmarkFolders.sorted(),
                blockedPageTitles: blockedTitles)
        }
    }

    private func confirmSourceDeletion(ids: [SourceID], unlink: Bool) {
        for id in ids { store.deleteSource(id, unlinkIncomingLinks: unlink) }
        pendingDeletion = nil
    }

    private var deletionDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func deletionDialogTitle(for pending: PendingSourceDeletion) -> String {
        if !pending.blockedPageTitles.isEmpty { return "Can't Delete Source" }
        return pending.ids.count == 1 ? "Delete Source?" : "Delete \(pending.ids.count) Sources?"
    }

    private func deletionDialogMessage(for pending: PendingSourceDeletion) -> String {
        if !pending.blockedPageTitles.isEmpty {
            let names = pending.blockedPageTitles.joined(separator: ", ")
            return "This source is referenced as evidence by page versions (\(names)). Remove those references before deleting."
        }
        var lines: [String] = []
        if !pending.linkingPageTitles.isEmpty {
            let names = pending.linkingPageTitles.joined(separator: ", ")
            let noun = pending.linkingPageTitles.count == 1 ? "page" : "pages"
            lines.append("Cited by \(pending.linkingPageTitles.count) \(noun): \(names).")
        }
        if pending.bookmarkCount > 0 {
            let noun = pending.bookmarkCount == 1 ? "bookmark" : "bookmarks"
            let where_ = pending.bookmarkFolders.joined(separator: ", ")
            lines.append("\(pending.bookmarkCount) \(noun) point to this and will be removed (\(where_)).")
        }
        if !pending.linkingPageTitles.isEmpty {
            lines.append("Unlink and Delete converts the citations to plain text.")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func deletionDialogActions(for pending: PendingSourceDeletion) -> some View {
        if !pending.blockedPageTitles.isEmpty {
            Button("OK", role: .cancel) { pendingDeletion = nil }
        } else if !pending.linkingPageTitles.isEmpty {
            Button("Unlink and Delete", role: .destructive) {
                confirmSourceDeletion(ids: pending.ids, unlink: true)
            }
            Button("Delete", role: .destructive) {
                confirmSourceDeletion(ids: pending.ids, unlink: false)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } else {
            Button("Delete", role: .destructive) {
                confirmSourceDeletion(ids: pending.ids, unlink: false)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
    }
}

/// State carried by the incoming-reference delete-confirmation dialog
/// (issue #219). When `blockedPageTitles` is non-empty, the source can't be
/// deleted at all (provenance-restricted) and only an OK button is shown.
private struct PendingSourceDeletion: Identifiable {
    let id = UUID()
    let ids: [SourceID]
    let linkingPageTitles: [String]
    let bookmarkCount: Int
    let bookmarkFolders: [String]
    let blockedPageTitles: [String]
}
