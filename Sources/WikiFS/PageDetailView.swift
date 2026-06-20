import SwiftUI
import WikiFSCore

/// Reader-first surface for the selected page. Manual editing is an explicit mode:
/// the default state renders the page as an article, while Edit reveals the source
/// editor and keeps the existing autosave buffers intact.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunBanner(isVisible: store.isAgentRunning)

            if isEditing {
                PageEditorView(store: store,
                    onSave: { toggleEditing() },
                    onCancel: { isEditing = false })
            } else {
                PageReaderView(store: store,
                    updatedAt: pageUpdatedAt,
                    mountPath: pageMountPath,
                    onEdit: { isEditing = true })
            }
        }
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
        .onChange(of: store.selection) {
            isEditing = false
        }
        .onChange(of: store.isAgentRunning) { _, isRunning in
            if isRunning {
                isEditing = false
            }
        }
    }

    private var pageUpdatedAt: Date? {
        guard let selection = store.selection,
              case .page(let id) = selection else { return nil }
        return store.summaries.first(where: { $0.id == id })?.updatedAt
    }

    private var pageMountPath: String? {
        guard let selection = store.selection,
              case .page(let id) = selection else { return nil }
        guard let title = store.summaries.first(where: { $0.id == id })?.title,
              let root = fileProvider.path else { return nil }
        let leaf = FilenameEscaping.byTitleFilename(title: title, pageID: id.rawValue)
        return "\(root)/pages/by-title/\(leaf)"
    }

    private func toggleEditing() {
        if isEditing {
            store.flushPendingSave()
        }
        isEditing.toggle()
    }

}
