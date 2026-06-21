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

    @State private var isSourcesExpanded = true

    var body: some View {
        Section {
            if isSourcesExpanded {
                ForEach(filteredSources) { source in
                    sourceRow(source)
                }
            }
        } header: {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: isSourcesExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Sources").font(.headline).foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { isSourcesExpanded.toggle() }
                }
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
            onIngestSelected: ingestAction
        )
        .tag(WikiSelection.source(source.id))
    }
}
