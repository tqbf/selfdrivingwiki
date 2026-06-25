import SwiftUI
import Textual

/// Leaf renderer for Claude-authored prose in the agent transcript. Claude often
/// emits Markdown (lists, headings, code fences, links), so hand it to Textual's
/// block renderer instead of flattening it through a plain `Text`.
struct AgentMarkdownText: View {
    let markdown: String

    var body: some View {
        StructuredText(markdown: markdown)
            .id(markdown)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    AgentMarkdownText(
        markdown: """
        ## Answer

        - **One** thing
        - `Another` thing

        ```sh
        wikictl page list
        ```
        """
    )
    .padding()
    .frame(width: 360)
}
