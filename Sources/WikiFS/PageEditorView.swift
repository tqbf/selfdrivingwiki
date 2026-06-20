import SwiftUI
import WikiFSCore

/// Focused manual source editor for the selected page. It binds directly to the
/// model's draft buffers; autosave is triggered via `.onChange` so it uses the
/// existing debounce and edit-lock behavior.
struct PageEditorView: View {
    @Bindable var store: WikiStoreModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            HStack(spacing: 10) {
                Button("Save Changes", systemImage: "checkmark.circle") {
                    onSave()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Cancel", systemImage: "xmark.circle") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.vertical, PageEditorMetrics.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .disabled(store.isAgentRunning)
    }
}
