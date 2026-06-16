import SwiftUI
import Textual
import WikiFSCore

/// Live, read-only render of the page body. The preview keeps wiki-specific
/// preprocessing here, then hands the resulting CommonMark document to Textual's
/// block renderer so headings, lists, rules, code, and paragraphs are laid out as
/// real Markdown rather than one collapsed inline text run.
///
/// Footnotes: Foundation leaves `[^id]` references and `[^id]: …` definitions as
/// literal text, so the preview first runs a pure `WikiFootnoteMarkdown` pass.
/// References become local note links (`wiki-footnote://…`) and definitions are
/// appended as an ordered notes section after the body. The stored wiki source
/// stays unchanged.
///
/// Wiki-links: CommonMark has no `[[…]]`, so before rendering we run the document
/// through `WikiLinkMarkdown.linkified` (in `WikiFSCore`), which rewrites every
/// `[[Title]]` / `[[Target|alias]]` into a real Markdown link on the private
/// `wiki://` scheme — EXCEPT inside code spans/fences, which stay literal. A
/// link whose target resolves to a page navigates on click; an unresolved one is
/// inert. The on-disk body is never rewritten — this is preview-only.
struct MarkdownPreview: View {
    @Bindable var store: WikiStoreModel
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to preview yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    StructuredText(markdown: renderedMarkdown)
                        .textual.textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(PageEditorMetrics.contentInset)
        }
        // Intercept clicks on the private wiki:// scheme and drive the SAME
        // selection seam the sidebar uses (§3.1/§3.5: go through the model, never
        // mutate selection ad hoc). A resolved link navigates; an unresolved
        // (missing) one is a gentle no-op. Real external links fall through to
        // the system browser via .systemDefault.
        .environment(\.openURL, OpenURLAction { url in
            guard let title = WikiLinkMarkdown.target(from: url) else {
                if WikiFootnoteMarkdown.isFootnoteURL(url) {
                    return .handled
                }
                return .systemAction
            }
            if WikiLinkMarkdown.isResolvedURL(url) {
                store.selectPage(byTitle: title)
            }
            return .handled
        })
    }

    private var renderedMarkdown: String {
        let renderedFootnotes = WikiFootnoteMarkdown.rendered(markdown)
        let body = linkified(renderedFootnotes.bodyMarkdown)
        guard !renderedFootnotes.footnotes.isEmpty else { return body }

        let footnotes = renderedFootnotes.footnotes
            .map { "\($0.number). \(linkified($0.markdown))" }
            .joined(separator: "\n")
        return "\(body)\n\n---\n\n\(footnotes)"
    }

    private func linkified(_ body: String) -> String {
        WikiLinkMarkdown.linkified(body) { store.pageExists(title: $0) }
    }
}

#Preview {
    let url = URL.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).sqlite")
    let store = try! SQLiteWikiStore(databaseURL: url)
    let model = WikiStoreModel(store: store)
    return MarkdownPreview(
        store: model,
        markdown: "# Hello\n\nThis is **bold**, a [[Real Page]] and a [[Ghost Page]]."
    )
    .frame(width: 360, height: 240)
}
