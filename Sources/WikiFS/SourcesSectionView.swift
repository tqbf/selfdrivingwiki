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
        // Single-source share via the File Provider mount path.
        let shareAction: (() -> Void)? = {
            guard let path = fileProvider.sourceMountPath(for: source) else { return nil }
            let url = URL(fileURLWithPath: path)
            return {
                // Force the daemon to materialise the file synchronously so
                // NSSharingServicePicker can determine the UTI.
                do {
                    let values = try url.resourceValues(forKeys: [.contentTypeKey])
                    if let type = values.contentType {
                        DebugLog.fileprovider("Share source sidebar: UTI=\(type.identifier)")
                    } else {
                        DebugLog.fileprovider("Share source sidebar: no contentType in values for \(path)")
                    }
                } catch {
                    DebugLog.fileprovider("Share source sidebar: resourceValues error=\(error.localizedDescription) path=\(path)")
                }
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
        }()

        // Batch share — appears when 2+ sources are selected. Collects every
        // selected source's mount path, materialises each, and passes all URLs
        // to a single NSSharingServicePicker.
        let batchShareAction: (() -> Void)? = {
            guard ids.count > 1 else { return nil }
            let selectedIDs = ids
            return {
                let urls: [URL] = selectedIDs.compactMap { id in
                    guard let src = store.sources.first(where: { $0.id == id }),
                          let path = fileProvider.sourceMountPath(for: src) else { return nil }
                    let url = URL(fileURLWithPath: path)
                    let _ = try? url.resourceValues(forKeys: [.contentTypeKey])
                    return url
                }
                guard !urls.isEmpty else { return }
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
        }()
        return SourceRow(
            source: source,
            hasBeenIngested: store.isSourceIngested(source),
            isIngesting: ingestingSourceIDs.contains(source.id),
            isExtracting: extractingSourceIDs.contains(source.id),
            isSelected: ids.contains(source.id),
            onOpen: { Task { await fileProvider.openSource(id: source.id) } },
            onRemove: { store.deleteSource(source.id) },
            onRename: { beginRename(source) },
            onIngestSelected: ingestAction,
            onShare: shareAction,
            onShareSelected: batchShareAction
        )
        .tag(WikiSelection.source(source.id))
    }
}
