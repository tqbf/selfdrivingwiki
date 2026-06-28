import SwiftUI
import WikiFSCore

/// The Sources section of the sidebar — filter picker, native multi-select rows,
/// and right-click → Ingest / Extract.
struct SourcesSectionView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderSpike
    let manager: WikiManager
    let launcher: AgentLauncher
    /// Sources whose agent run is in flight (agent phase) — "Ingesting…" spinner.
    var ingestingSourceIDs: Set<PageID> = []
    /// Sources whose pdf2md conversion is in flight (extraction phase) —
    /// "Extracting…" spinner. Independent of `ingestingSourceIDs`.
    var extractingSourceIDs: Set<PageID> = []
    @Binding var showingAddFromZotero: Bool
    @Binding var showingImportMarkdown: Bool
    var onAddFromURL: () -> Void
    var isZoteroConfigured: Bool = false

    @State private var sourceFilter: SourceFilter = .all
    @Binding var listSelection: Set<WikiSelection>
    @Binding var activeSection: SidebarView.ActiveSection

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

    private var selectedSourceIDs: Set<PageID> {
        Set(listSelection.compactMap { sel in
            if case .source(let id) = sel { return id }
            return nil
        })
    }

    // Rename dialog state (mirrors the page-row rename in SidebarView).
    @State private var renameTarget: SourceSummary?
    @State private var renameText = ""
    /// Set when the user taps Ingest on a multi-select that includes
    /// already-ingested sources — prompts before re-ingesting.
    @State private var showBatchReingestConfirmation = false
    @State private var pendingBatchIngestIDs: [PageID] = []
    @State private var pendingReingestNames: [String] = []

    var body: some View {
        Section {
            if isZoteroConfigured {
                Button {
                    showingAddFromZotero = true
                } label: {
                    SidebarModeRow(title: "Add from Zotero…", subtitle: "Browse Zotero library",
                        systemImage: "books.vertical")
                }
                .buttonStyle(.plain)
                .help("Browse your Zotero library and add a PDF or Markdown attachment")
            }

            Button {
                onAddFromURL()
            } label: {
                SidebarModeRow(title: "Add from URL…", subtitle: "Web page or PDF",
                    systemImage: "link.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Fetch a web page or PDF by URL as source material")

            Button {
                if let url = WikiFilePanels.chooseFile(title: "Add File", prompt: "Import") {
                    Task {
                        await store.ingest(fileURLs: [url])
                    }
                }
            } label: {
                SidebarModeRow(title: "Add File…", subtitle: "Pick one",
                    systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Add a single file from the filesystem as source material")

            Button {
                showingImportMarkdown = true
            } label: {
                SidebarModeRow(title: "Add Folder…", subtitle: "Pick many",
                    systemImage: "doc.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Add all .md and .pdf files from a folder as source material")

            Divider()

            HStack {
                Text("Show").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Filter", selection: $sourceFilter) {
                    ForEach(SourceFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            ForEach(filteredSources) { source in
                sourceRow(source)
            }
        } header: {
            Text("Sources").font(.headline).foregroundStyle(.primary)
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
                    store: store, manager: manager, fileProvider: fileProvider)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The following sources have already been ingested:\n\(pendingReingestNames.joined(separator: "\n"))\n\nRunning ingest again may create duplicate pages.")
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
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

    private func sourceRow(_ source: SourceSummary) -> some View {
        let ids = selectedSourceIDs
        let ingestAction: (() -> Void)? = ids.isEmpty ? nil : {
            let reingestNames = ids.compactMap { id -> String? in
                guard let s = store.sources.first(where: { $0.id == id }),
                      store.isSourceIngested(s) else { return nil }
                return s.displayName ?? s.filename
            }
            if !reingestNames.isEmpty {
                pendingBatchIngestIDs = Array(ids)
                pendingReingestNames = reingestNames
                showBatchReingestConfirmation = true
            } else {
                launcher.ingestSources(sourceIDs: Array(ids),
                    store: store, manager: manager, fileProvider: fileProvider)
            }
        }
        // Single-source ingest — always shown. Same re-ingest guard as batch.
        let singleIngestAction: (() -> Void)? = {
            let id = source.id
            let reingestNames: [String] = {
                guard let s = store.sources.first(where: { $0.id == id }),
                      store.isSourceIngested(s) else { return [] }
                return [s.displayName ?? s.filename]
            }()
            return {
                if !reingestNames.isEmpty {
                    pendingBatchIngestIDs = [id]
                    pendingReingestNames = reingestNames
                    showBatchReingestConfirmation = true
                } else {
                    launcher.ingestSources(sourceIDs: [id],
                        store: store, manager: manager, fileProvider: fileProvider)
                }
            }
        }()
        // Single-source share — resolves the canonical URL from the daemon
        // via the source-by-name identifier, same pattern as openSource.
        let shareAction: (() -> Void)? = {
            // Show the item only when the domain is active.
            guard fileProvider.path != nil else { return nil }
            let sourceID = source.id
            return {
                Task {
                    guard let url = await fileProvider.resolveSourceByNameURL(id: sourceID) else { return }
                    DebugLog.fileprovider("Share source sidebar: \(url.lastPathComponent)")
                    let picker = NSSharingServicePicker(items: [url])
                    let mouseScreen = NSEvent.mouseLocation
                    guard let window = NSApplication.shared.keyWindow,
                          let contentView = window.contentView else { return }
                    let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                    let viewPoint = contentView.convert(windowPoint, from: nil)
                    picker.show(
                        relativeTo: NSRect(origin: viewPoint, size: NSSize(width: 1, height: 1)),
                        of: contentView, preferredEdge: .minY)
                }
            }
        }()

        // Batch share — appears when 2+ sources are selected.  Resolves all
        // URLs in parallel via the daemon, then passes them to one picker.
        let batchShareAction: (() -> Void)? = {
            let count = ids.count
            guard count > 1 else { return nil }
            let selectedIDs = ids
            return {
                Task {
                    let urls: [URL] = await withTaskGroup(of: URL?.self) { group in
                        for id in selectedIDs {
                            group.addTask { await fileProvider.resolveSourceByNameURL(id: id) }
                        }
                        var results: [URL] = []
                        for await url in group { if let url { results.append(url) } }
                        return results
                    }
                    guard !urls.isEmpty else { return }
                    DebugLog.fileprovider("Share source batch: \(urls.count) urls")
                    let picker = NSSharingServicePicker(items: urls)
                    let mouseScreen = NSEvent.mouseLocation
                    guard let window = NSApplication.shared.keyWindow,
                          let contentView = window.contentView else { return }
                    let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                    let viewPoint = contentView.convert(windowPoint, from: nil)
                    picker.show(
                        relativeTo: NSRect(origin: viewPoint, size: NSSize(width: 1, height: 1)),
                        of: contentView, preferredEdge: .minY)
                }
            }
        }()
        return SourceRow(
            source: source,
            hasBeenIngested: store.isSourceIngested(source),
            isIngesting: ingestingSourceIDs.contains(source.id),
            isExtracting: extractingSourceIDs.contains(source.id),
            isSelected: ids.contains(source.id),
            onOpen: { Task { await fileProvider.openSource(id: source.id) } },
            onOpenSelected: {
                for id in ids { Task { await fileProvider.openSource(id: id) } }
            },
            onOpenInBackgroundSelected: {
                for id in ids { store.openTabInBackground(.source(id)) }
            },
            openSelectedCount: ids.count,
            onRemove: { store.deleteSource(source.id) },
            onRemoveSelected: { for id in ids { store.deleteSource(id) } },
            deleteSelectedCount: ids.count,
            onRename: { beginRename(source) },
            onIngest: singleIngestAction,
            onIngestSelected: ingestAction,
            ingestSelectedCount: ids.count,
            onShare: shareAction,
            onOpenInBackground: { store.openTabInBackground(.source(source.id)) },
            onShareSelected: batchShareAction,
            shareSelectedCount: ids.count,
            onExtract: {
                guard let data = store.sourceBytes(id: source.id) else { return }
                Task { await launcher.extractPDF(store: store, id: source.id, filename: source.filename, data: data) }
            },
            onExtractSelected: {
                let toExtract = ids.compactMap { id -> (PageID, String, Data)? in
                    guard let s = store.sources.first(where: { $0.id == id }),
                          s.mimeType == "application/pdf",
                          store.processedMarkdownHead(for: s) == nil,
                          let data = store.sourceBytes(id: id) else { return nil }
                    return (id, s.filename, data)
                }
                guard !toExtract.isEmpty else { return }
                Task {
                    for item in toExtract {
                        await launcher.extractPDF(store: store, id: item.0, filename: item.1, data: item.2)
                    }
                }
            },
            extractCount: ids.filter { id in
                guard let s = store.sources.first(where: { $0.id == id }),
                      s.mimeType == "application/pdf",
                      store.processedMarkdownHead(for: s) == nil else { return false }
                return true
            }.count,
            canExtract: source.mimeType == "application/pdf"
                && store.processedMarkdownHead(for: source) == nil
        )
        .tag(WikiSelection.source(source.id))
    }

}
