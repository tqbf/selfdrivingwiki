import SwiftUI
import WikiFSCore

/// Reader-first surface for the singleton system-prompt document — the agent's
/// instructions, projected read-only at the wiki root as `CLAUDE.md` and
/// `AGENTS.md`. Like `PageDetailView`, the default state renders the prompt as
/// formatted markdown; manual editing is an explicit mode (Cmd+E) that reveals a
/// monospaced source editor and keeps the existing system-prompt autosave intact.
/// There is no editable title (it is a singleton); a fixed header explains where
/// the document surfaces and stays visible in both modes.
struct SystemPromptDetailView: View {
    @Bindable var store: WikiStoreModel
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("The agent reads this each run. Projected read-only at the wiki root as **CLAUDE.md** and **AGENTS.md**.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(store.isAgentRunning ? "Agent updating wiki…" : "Edit",
                           systemImage: "pencil") { isEditing = true }
                        .disabled(store.isAgentRunning)
                        .help(store.isAgentRunning
                              ? "Editing is paused while the agent is updating the wiki"
                              : "Edit the system prompt source")
                }
            }
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            if isEditing {
                editor
            } else {
                reader
            }
        }
        // Read-only while the agent runs (decision #6); autosave paused in the model.
        .disabled(store.isAgentRunning)
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

    // MARK: - Modes

    /// Default mode: the prompt rendered as formatted, read-only markdown.
    private var reader: some View {
        MarkdownPreview(store: store, markdown: store.draftSystemPrompt,
                        currentSelection: store.selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: PageEditorMetrics.previewMinHeight)
    }

    /// Edit mode: the monospaced source editor, bound to the live draft buffer.
    /// Autosave fires via `.onChange` (not a `Binding(get:set:)`, per swiftui-pro).
    /// Save/Cancel buttons live inline so they are visually part of the editor.
    private var editor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $store.draftSystemPrompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, PageEditorMetrics.contentInset - 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: PageEditorMetrics.editorMinHeight)
                .onChange(of: store.draftSystemPrompt) { store.systemPromptChanged() }

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            HStack(spacing: 10) {
                Button("Save Changes", systemImage: "checkmark.circle") {
                    toggleEditing()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Cancel", systemImage: "xmark.circle") {
                    isEditing = false
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.vertical, PageEditorMetrics.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func toggleEditing() {
        if isEditing {
            store.flushPendingSystemPromptSave()
        }
        isEditing.toggle()
    }
}
