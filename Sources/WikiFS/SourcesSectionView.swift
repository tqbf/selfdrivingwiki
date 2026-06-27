import SwiftUI
import WikiFSCore

/// The Sources section of the sidebar — filter picker, native multi-select rows,
/// and right-click → Ingest Selected.
struct SourcesSectionView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderSpike
    /// Sources whose agent run is in flight (agent phase) — "Ingesting…" spinner.
    var ingestingSourceIDs: Set<PageID> = []
    /// Sources whose pdf2md conversion is in flight (extraction phase) —
    /// "Extracting…" spinner. Independent of `ingestingSourceIDs`.
    var extractingSourceIDs: Set<PageID> = []
    var onBatchIngest: (([PageID]) -> Void)? = nil

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

    var body: some View {
        Section {
            ForEach(filteredSources) { source in
                sourceRow(source)
            }
        } header: {
            HStack(spacing: 0) {
                Text("Sources").font(.headline).foregroundStyle(.primary)
                Spacer()
                Picker("Filter", selection: $sourceFilter) {
                    ForEach(SourceFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
                .help("Filter sources by ingest status")
            }
        }
        .alert("Rename Source", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
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
            onBatchIngest?(Array(ids))
        }
        return SourceRow(
            source: source,
            hasBeenIngested: store.isSourceIngested(source),
            isIngesting: ingestingSourceIDs.contains(source.id),
            isExtracting: extractingSourceIDs.contains(source.id),
            isSelected: ids.contains(source.id),
            onOpen: { Task { await fileProvider.openSource(id: source.id) } },
            onRemove: { store.deleteSource(source.id) },
            onRename: { beginRename(source) },
            onIngestSelected: ingestAction
        )
        .tag(WikiSelection.source(source.id))
    }
}
