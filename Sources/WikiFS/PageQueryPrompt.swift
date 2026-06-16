import SwiftUI

/// Compact query composer shown at the bottom of every page reader. It mirrors a
/// native search/question field: always visible, modest in scale, and submit-on-
/// Return without sending the user hunting through the toolbar.
struct PageQueryPrompt: View {
    let isRunning: Bool
    let onSubmit: (String) -> Void
    @State private var queryText = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask this wiki a question…", text: $queryText, axis: .vertical)
                .font(.callout)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit(submit)
                .disabled(isRunning)

            Button("Query", systemImage: "arrow.up.circle.fill", action: submit)
                .labelStyle(.iconOnly)
                .font(.title3)
                .disabled(isRunning || trimmedQuery.isEmpty)
                .help("Query the wiki")
        }
        .frame(maxWidth: PageEditorMetrics.readableContentWidth)
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, PageEditorMetrics.sectionSpacing)
    }

    private var trimmedQuery: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let question = trimmedQuery
        guard !question.isEmpty else { return }
        onSubmit(question)
        queryText = ""
    }
}
