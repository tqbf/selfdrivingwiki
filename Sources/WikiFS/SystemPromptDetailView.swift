import SwiftUI
import WikiFSCore

/// Editor + live preview for the singleton system-prompt document — the agent's
/// instructions, projected read-only at the wiki root as `CLAUDE.md` and
/// `AGENTS.md`. Mirrors `PageDetailView` but there is no editable title (it is a
/// singleton); instead a fixed header explains where the document surfaces. The
/// editor binds to the model's `draftSystemPrompt`; autosave fires via
/// `.onChange` (not a `Binding(get:set:)`, per swiftui-pro).
struct SystemPromptDetailView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentRunBanner(isVisible: store.isAgentRunning)

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("The agent reads this each run. Projected read-only at the wiki root as **CLAUDE.md** and **AGENTS.md**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            TextEditor(text: $store.draftSystemPrompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, PageEditorMetrics.contentInset - 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: PageEditorMetrics.editorMinHeight)
                .onChange(of: store.draftSystemPrompt) { store.systemPromptChanged() }

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            MarkdownPreview(store: store, markdown: store.draftSystemPrompt)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PageEditorMetrics.previewMinHeight)
                .background(.quaternary.opacity(0.25))
        }
        // Read-only while the agent runs (decision #6); autosave paused in the model.
        .disabled(store.isAgentRunning)
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
    }
}
