import SwiftUI
import WikiFSCore

/// Live, read-only render of the page body. Uses Foundation's built-in
/// `AttributedString(markdown:)` with inline-only interpretation — the accepted
/// v0 choice (INITIAL.md §4 "avoid a full markdown engine"). The body is split
/// on blank lines so paragraphs and headings read as distinct blocks rather
/// than one collapsed run; each block is its own selectable `Text`.
///
/// Wiki-links: CommonMark has no `[[…]]`, so before parsing each block we run it
/// through `WikiLinkMarkdown.linkified` (in `WikiFSCore`), which rewrites every
/// `[[Title]]` / `[[Target|alias]]` into a real Markdown link on the private
/// `wiki://` scheme — EXCEPT inside code spans/fences, which stay literal. A
/// link whose target resolves to a page renders as a normal accent link and
/// navigates on click; an unresolved one renders dimmed and is inert. The
/// on-disk body is never rewritten — this is preview-only.
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
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        Text(rendered(block))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PageEditorMetrics.contentInset)
        }
        // Intercept clicks on the private wiki:// scheme and drive the SAME
        // selection seam the sidebar uses (§3.1/§3.5: go through the model, never
        // mutate selection ad hoc). A resolved link navigates; an unresolved
        // (missing) one is a gentle no-op. Real external links fall through to
        // the system browser via .systemDefault.
        .environment(\.openURL, OpenURLAction { url in
            guard let title = WikiLinkMarkdown.target(from: url) else {
                return .systemAction
            }
            if WikiLinkMarkdown.isResolvedURL(url) {
                store.selectPage(byTitle: title)
            }
            return .handled
        })
    }

    /// Split the source into paragraph-ish blocks on blank lines.
    private var blocks: [String] {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Render one block: rewrite its wiki-links, parse as inline Markdown, then
    /// dim any unresolved (`wiki://missing`) link runs. Falls back to the raw
    /// text if markdown parsing fails.
    private func rendered(_ block: String) -> AttributedString {
        let linkified = WikiLinkMarkdown.linkified(block) { store.pageExists(title: $0) }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: linkified, options: options) else {
            return AttributedString(block)
        }
        dimUnresolvedLinks(in: &attributed)
        return attributed
    }

    /// Recolor unresolved wiki-link runs so a dead link reads as "no page here":
    /// secondary foreground, no accent. Resolved links keep the default accent
    /// link styling. We can't gate the parse per-link, so we style after the fact
    /// by inspecting each run's link URL.
    private func dimUnresolvedLinks(in text: inout AttributedString) {
        for run in text.runs where run.link != nil {
            guard let url = run.link, url.scheme == WikiLinkMarkdown.scheme else { continue }
            if !WikiLinkMarkdown.isResolvedURL(url) {
                text[run.range].foregroundColor = .secondary
            }
        }
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
