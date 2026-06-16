import SwiftUI
import WikiFSCore

/// Secondary Help-menu surface for the exact `claude -p` command and prompts.
struct ClaudePromptHelpView: View {
    private let documents = ClaudePromptHelp.documents
    @State private var selectedDocumentID: ClaudePromptHelpDocument.ID? = "query"

    var body: some View {
        NavigationSplitView {
            List(documents, selection: $selectedDocumentID) { document in
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(document.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .navigationTitle("Prompts")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selectedDocument {
                ScrollView {
                    PromptHelpSectionView(document: selectedDocument)
                        .padding(PageEditorMetrics.contentInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .navigationTitle(selectedDocument.title)
            } else {
                ContentUnavailableView {
                    Label("No Prompt Selected", systemImage: "text.page")
                } description: {
                    Text("Choose a prompt from the sidebar.")
                }
            }
        }
        .navigationTitle("Claude Prompt Templates")
        .frame(minWidth: 720, minHeight: 560)
    }

    private var selectedDocument: ClaudePromptHelpDocument? {
        let selectedID = selectedDocumentID ?? "query"
        return documents.first { $0.id == selectedID } ?? documents.first
    }
}

#Preview {
    ClaudePromptHelpView()
}
