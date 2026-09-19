import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSCore

/// The Sources section — a native header (Add buttons, a filter menu icon,
/// search) above an AppKit `NSTableView` (`SourcesListView`). Mirrors
/// `PagesContainerView` / `BookmarksContainerView`. Filtering and search live
/// here (SwiftUI); the AppKit list below stays dumb and just renders the
/// computed array.
struct SourcesContainerView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderFacade
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: any WikiSessionProtocol
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
    /// Display order backing the "Sort by" menu. `lastUpdated` is the
    /// store's native order — today's default.
    @State private var sourceSort: SourceSortOrder = .lastUpdated
    @State private var renameTarget: SourceSummary?
    @State private var renameText = ""
    @State private var showBatchReingestConfirmation = false
    @State private var pendingBatchIngestIDs: [SourceID] = []
    @State private var pendingReingestNames: [String] = []
    /// Non-nil while the bookmark-target picker is open for a source selection.
    @State private var addToBookmarksContext: BookmarkTargetPickerContext?
    /// Non-nil while a delete-confirmation surface is on screen (issue #219
    /// hardening): the typed outcome produced by the shared
    /// `DeletionConfirmationCoordinator`.
    @State private var deletionOutcome: DeletionConfirmationOutcome?
    /// The source ids behind `deletionOutcome` — what the action handler deletes.
    @State private var pendingDeletionIDs: [SourceID] = []

    enum SourceFilter: String, CaseIterable {
        case all = "All"
        case ready = "Ready"
        case ingested = "Processed"
    }

    /// Display order for the source list (follow-up to #241's Bookmarks
    /// header). `lastUpdated` is the store's native `ORDER BY updated_at
    /// DESC` — today's behavior — and the default. Raw value matches the
    /// case name, mirroring `PageSortOrder`, should the choice persist later.
    enum SourceSortOrder: String, CaseIterable {
        /// Most recently updated first — the store's native order (default).
        case lastUpdated
        /// Most recently added first (`created_at DESC`).
        case newestFirst
        /// Display name, localized case-insensitive, A–Z.
        case titleAZ

        /// Sorts the source list for display. Pure; unit-tested without a
        /// live store. Equal keys tie-break on `id.rawValue` (a ULID, so
        /// monotonic by ingest time) for a deterministic order.
        nonisolated func sorted(_ sources: [SourceSummary]) -> [SourceSummary] {
            switch self {
            case .lastUpdated:
                return sources.sorted { a, b in
                    if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                    return a.id.rawValue < b.id.rawValue
                }
            case .newestFirst:
                return sources.sorted { a, b in
                    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                    return a.id.rawValue < b.id.rawValue
                }
            case .titleAZ:
                return sources.sorted { a, b in
                    let order = a.effectiveName.localizedCaseInsensitiveCompare(b.effectiveName)
                    if order == .orderedSame { return a.id.rawValue < b.id.rawValue }
                    return order == .orderedAscending
                }
            }
        }
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
    ///
    /// The display sort applies only when NOT searching: search results are
    /// relevance-ranked by the engine, and re-ranking them would destroy
    /// that (mirrors `PagesContainerView`, which never sorts search results).
    private var visibleSources: [SourceSummary] {
        if store.sourceSearchQuery.isEmpty {
            return sourceSort.sorted(filteredSources.filter { $0.isPrimary })
        }
        return store.sourceSearchResults.filter { $0.isPrimary }
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcesHeader
            Divider()
            ZStack(alignment: .topLeading) {
                SourcesListView(store: store, fileProvider: fileProvider,
                                session: session, launcher: launcher,
                                ingestingSourceIDs: ingestingSourceIDs,
                                extractingSourceIDs: tracker.extractingSourceIDs
                                    .union(store.importExtractingSourceIDs),
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
        .deletionOutcomeDialog(
            $deletionOutcome,
            onAction: { action in
                handleDeletionAction(action)
            },
            onOpenPage: { pageID in
                // A clickable blocking page: open it so the user can remove
                // the provenance reference, then retry the delete.
                store.openTab(.page(pageID))
            }
        )
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
                filterMenu
                sortMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            sourceSearchBar
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
    }

    /// The "Show" source filter (issue follow-up to #241) — a filter icon
    /// whose dropdown menu lists All / Ready / Processed, replacing the
    /// former "Show" caption row. The `Picker` inside the `Menu` checks the
    /// current choice; the icon tints accent while a non-default filter is
    /// active. Same `Menu { Picker … }` pattern as the Bookmarks header.
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $sourceFilter) {
                Text("All").tag(SourceFilter.all)
                Text("Ready").tag(SourceFilter.ready)
                Text("Processed").tag(SourceFilter.ingested)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(sourceFilter == .all ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show")
    }

    /// The "Sort by" control — a sort icon whose dropdown lists the display
    /// orders, the same `Menu { Picker … }` pattern as the filter icon.
    /// The icon tints accent while a non-default (non-Last Updated) sort is
    /// active. Last Updated is the store's native order — the default.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sourceSort) {
                Text("Last Updated").tag(SourceSortOrder.lastUpdated)
                Text("Newest First").tag(SourceSortOrder.newestFirst)
                Text("Title A–Z").tag(SourceSortOrder.titleAZ)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(sourceSort == .lastUpdated ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by")
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

    // MARK: - Delete with incoming-reference warning (issue #219 hardening)

    /// Aggregate the incoming citations + bookmarks + provenance blockers for
    /// the selected sources via the shared coordinator, then either delete
    /// immediately (nothing references them) or route to the typed state.
    private func requestSourceDeletion(_ ids: [SourceID]) {
        pendingDeletionIDs = ids
        let coordinator = DeletionConfirmationCoordinator(
            kind: .source,
            loadImpacts: {
                try ids.map { try store.deletionImpact(forSource: $0) }
            },
            onDelete: { decision in
                performSourceDeletion(ids: ids, decision: decision)
            },
            pageTitle: { id in
                store.summaries.first { $0.id == id }?.title
            },
            selectionCount: ids.count)
        let outcome = coordinator.evaluate()
        if case .deleteImmediately = outcome {
            // No references, no blockers — delete without a dialog.
            coordinator.perform(.delete)
        } else {
            deletionOutcome = outcome
        }
    }

    private func performSourceDeletion(ids: [SourceID], decision: DeletionDecision) {
        // ONE protected transaction for the whole selection; on failure the
        // model surfaces the store error and returns nil (nothing changed).
        _ = store.performSourceDeletion(ids, unlinkIncomingLinks: decision == .unlink)
    }

    private func handleDeletionAction(_ action: DeletionDialogAction) {
        let ids = pendingDeletionIDs
        switch action {
        case .unlinkAndDelete: performSourceDeletion(ids: ids, decision: .unlink)
        case .delete: performSourceDeletion(ids: ids, decision: .preserve)
        case .cancel: break
        }
        pendingDeletionIDs = []
    }
}
