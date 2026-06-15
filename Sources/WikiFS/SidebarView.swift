import SwiftUI
import WikiFSCore

/// Page list. `List(selection:)` bound straight to the model's selection; rows
/// are `WikiPageSummary` (Identifiable, so no explicit `id:`). Both a
/// `.contextMenu` and `.swipeActions` expose Rename/Delete (§4.1 / §7.4), and
/// the modern inset + hidden-background list look matches Notes/Mail (§4.2).
struct SidebarView: View {
    @Bindable var store: WikiStoreModel
    /// Used to open an ingested file in its default app via its user-visible URL.
    let fileProvider: FileProviderSpike
    @State private var renameTarget: WikiPageSummary?
    @State private var renameText: String = ""

    var body: some View {
        List(selection: $store.selection) {
            Section("Pages") {
                ForEach(store.summaries) { summary in
                    Text(summary.title.isEmpty ? "Untitled" : summary.title)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .tag(summary.id)
                        .contextMenu {
                            Button("Rename") { beginRename(summary) }
                            Button("Delete", role: .destructive) { store.delete(summary.id) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { store.delete(summary.id) }
                        }
                }
            }
            // Files section appears only once at least one file is ingested. The
            // rows are management-only (no `.tag`), so they never feed the page
            // selection binding above — clicking one is a no-op on the detail pane.
            if !store.ingestedFiles.isEmpty {
                Section("Files") {
                    ForEach(store.ingestedFiles) { file in
                        IngestedFileRow(
                            file: file,
                            onOpen: { Task { await fileProvider.openIngestedFile(id: file.id) } },
                            onRemove: { store.deleteIngestedFile(file.id) }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .navigationTitle("WikiFS")
        .navigationSplitViewColumnWidth(
            min: PageEditorMetrics.sidebarMinWidth,
            ideal: PageEditorMetrics.sidebarIdealWidth
        )
        .toolbar {
            ToolbarItem {
                Button("New Page", systemImage: "plus") { store.newPage() }
            }
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
