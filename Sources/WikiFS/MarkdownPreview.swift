import SwiftUI
import Textual
import WikiFSCore

/// Live, read-only render of the page body. Regex preprocessing (footnote
/// expansion + wiki-link linkification) runs in a detached task so the view
/// shell appears immediately and the rendered text fills in after. For large
/// documents this avoids blocking the main thread during body evaluation.
struct MarkdownPreview: View {
    @Bindable var store: WikiStoreModel
    let markdown: String
    var contentInset: Bool = true

    @State private var renderedBody: String?
    @State private var renderTaskKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to preview yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let body = renderedBody {
                    StructuredText(markdown: body)
                        .id(body)
                        .textual.textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                }
            }
            .frame(maxWidth: contentInset ? PageEditorMetrics.readableContentWidth : .infinity,
                   alignment: .leading)
            .padding(contentInset ? PageEditorMetrics.contentInset : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let title = WikiLinkMarkdown.target(from: url) else {
                if WikiFootnoteMarkdown.isFootnoteURL(url) {
                    return .handled
                }
                return .systemAction
            }
            switch WikiLinkMarkdown.resolvedKind(from: url) {
            case .page:   store.selectPage(byTitle: title)
            case .source: store.selectSource(byDisplayName: title)
            case nil:     break
            }
            return .handled
        })
        .task(id: markdown) {
            let captured = markdown
            let key = UUID().uuidString
            renderTaskKey = key
            // Yield first so the view shell (ProgressView) renders before we
            // block the main actor on regex + linkification for large documents.
            await Task.yield()
            guard renderTaskKey == key else { return }
            renderedBody = renderMarkdown(captured)
            // Force a second yield so the UI can commit the rendered frame.
            await Task.yield()
        }
    }

    @MainActor
    private func renderMarkdown(_ raw: String) -> String {
        let renderedFootnotes = WikiFootnoteMarkdown.rendered(raw)
        let body = WikiLinkMarkdown.linkified(renderedFootnotes.bodyMarkdown) { [weak store] name, kind in
            kind == .source ? store?.sourceExists(displayName: name) ?? false : store?.pageExists(title: name) ?? false
        }
        guard !renderedFootnotes.footnotes.isEmpty else { return body }
        let footnotes = renderedFootnotes.footnotes
            .map { "\($0.number). \(WikiLinkMarkdown.linkified($0.markdown) { [weak store] n, k in k == .source ? store?.sourceExists(displayName: n) ?? false : store?.pageExists(title: n) ?? false })" }
            .joined(separator: "\n")
        return "\(body)\n\n---\n\n\(footnotes)"
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
