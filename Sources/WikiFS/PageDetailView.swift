import SwiftUI
import WikiFSCore

/// Editor + live preview for the selected page. The title field and body editor
/// bind directly to the model's draft buffers; autosave is triggered via
/// `.onChange` (NOT a `Binding(get:set:)`, per swiftui-pro). The preview reads
/// the same `draftBody`, so it updates live as the user types.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunBanner(isVisible: store.isAgentRunning)

            TextField("Title", text: $store.draftTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .textFieldStyle(.plain)
                .padding(.horizontal, PageEditorMetrics.contentInset)
                .padding(.top, PageEditorMetrics.contentInset)
                .padding(.bottom, PageEditorMetrics.sectionSpacing)
                .onChange(of: store.draftTitle) { store.titleChanged() }

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            TextEditor(text: $store.draftBody)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, PageEditorMetrics.contentInset - 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: PageEditorMetrics.editorMinHeight)
                .onChange(of: store.draftBody) { store.bodyChanged() }

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            MarkdownPreview(store: store, markdown: store.draftBody)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PageEditorMetrics.previewMinHeight)
                .background(.quaternary.opacity(0.25))
        }
        // The whole editor goes read-only while the agent runs (decision #6);
        // autosave is also paused in the model so an in-app save can't clobber the
        // agent's wikictl writes.
        .disabled(store.isAgentRunning)
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
    }
}
