import SwiftUI
import WikiFSCore

/// One titled prompt block in the Help-menu prompt reference.
struct PromptHelpSectionView: View {
    let document: ClaudePromptHelpDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(document.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PromptCodeBlockView(text: document.body)
        }
    }
}
