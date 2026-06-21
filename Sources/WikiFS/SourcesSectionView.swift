import SwiftUI
import WikiFSCore

/// The Files section of the sidebar — filter picker, native multi-select rows,
/// and right-click → Ingest Selected.
struct FilesSectionView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderSpike
    /// Files whose agent run is in flight (agent phase) — "Ingesting…" spinner.
    var ingestingFileIDs: Set<PageID> = []
    /// Files whose pdf2md conversion is in flight (extraction phase) —
    /// "Extracting…" spinner. Independent of `ingestingFileIDs`.
    var extractingFileIDs: Set<PageID> = []
    var onBatchIngest: (([PageID]) -> Void)? = nil

    @State private var fileFilter: FileFilter = .all
    @Binding var listSelection: Set<WikiSelection>
    @Binding var activeSection: SidebarView.ActiveSection

    enum FileFilter: String, CaseIterable {
        case all = "All"
        case ready = "Ready"
        case ingested = "Processed"
    }

    private var filteredFiles: [SourceSummary] {
        switch fileFilter {
        case .all: return store.sources
        case .ready: return store.sources.filter { !store.isSourceIngested($0) }
        case .ingested: return store.sources.filter { store.isSourceIngested($0) }
        }
    }

    private var selectedFileIDs: Set<PageID> {
        Set(listSelection.compactMap { sel in
            if case .source(let id) = sel { return id }
            return nil
        })
    }

    @State private var isFilesExpanded = true

    var body: some View {
        Section {
            if isFilesExpanded {
                ForEach(filteredFiles) { file in
                    fileRow(file)
                }
            }
        } header: {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: isFilesExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Files").font(.headline).foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { isFilesExpanded.toggle() }
                }
                Spacer()
                Picker("Filter", selection: $fileFilter) {
                    ForEach(FileFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
                .help("Filter files by ingest status")
            }
        }
    }

    private func fileRow(_ file: SourceSummary) -> some View {
        let ids = selectedFileIDs
        let ingestAction: (() -> Void)? = ids.isEmpty ? nil : {
            onBatchIngest?(Array(ids))
        }
        return IngestedFileRow(
            file: file,
            hasBeenIngested: store.isSourceIngested(file),
            isIngesting: ingestingFileIDs.contains(file.id),
            isExtracting: extractingFileIDs.contains(file.id),
            isSelected: ids.contains(file.id),
            onOpen: { Task { await fileProvider.openIngestedFile(id: file.id) } },
            onRemove: { store.deleteSource(file.id) },
            onIngestSelected: ingestAction
        )
        .tag(WikiSelection.source(file.id))
    }
}
