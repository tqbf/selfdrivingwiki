import SwiftUI
import Textual
import WikiFSCore

/// Live, read-only render of the page body. Footnote expansion + wiki-link
/// linkification run SYNCHRONOUSLY in `body` so `StructuredText` is built with
/// its final content during the first layout pass.
///
/// Why synchronous (reverts the `95d237f` `Task.yield()` deferral): Textual's
/// macOS text-selection overlay owns both the cursor and link hit-testing — both
/// gate on the selection model's laid-out link geometry (`model.url(for:)`).
/// When `StructuredText` is swapped in AFTER the first layout pass (the old
/// `ProgressView` → rendered swap), that geometry is stale until a scroll forces
/// relayout, so links are unclickable and the cursor stays the I-beam everywhere
/// until you scroll. Rendering in `body` attaches the model to final, laid-out
/// content up front.
///
/// Anchor scrolling: `StructuredText.Heading` already applies `.id(slug)` via
/// Textual (`Heading.swift:24`); `NumberedParagraphStyle` applies `.id("p\(n)")`
/// to paragraphs. The block list (via `AnchorBlock.parse`) maps fragments to ids.
struct MarkdownPreview: View {
    @Bindable var store: WikiStoreModel
    let markdown: String
    var contentInset: Bool = true
    /// The current selection this preview is rendering (page id or source id).
    /// Used to match against `store.pendingScrollAnchor`.
    var currentSelection: WikiSelection? = nil

    @State private var blocks: [AnchorBlock] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        // Render synchronously so StructuredText is built with
                        // its final content during the first layout pass (see the
                        // type doc). `renderNumbered` resets the paragraph counter
                        // and returns the rendered markdown in one call.
                        let rendered = renderNumbered(markdown)
                        StructuredText(markdown: rendered)
                            .id(rendered)
                            .textual.paragraphStyle(NumberedParagraphStyle())
                            .textual.textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: contentInset ? PageEditorMetrics.readableContentWidth : .infinity,
                       alignment: .leading)
                .padding(contentInset ? PageEditorMetrics.contentInset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(\.openURL, OpenURLAction { url in
                // Same-page anchor: scroll within current preview.
                if WikiLinkMarkdown.isSamePageAnchor(url),
                   let frag = WikiLinkMarkdown.fragment(from: url),
                   let id = resolveAnchor(frag, in: blocks) {
                    proxy.scrollTo(id, anchor: .top)
                    return .handled
                }
                guard let title = WikiLinkMarkdown.target(from: url) else {
                    if WikiFootnoteMarkdown.isFootnoteURL(url) {
                        return .handled
                    }
                    return .systemAction
                }
                let frag = WikiLinkMarkdown.fragment(from: url)
                switch WikiLinkMarkdown.resolvedKind(from: url) {
                case .page:   store.selectPage(byTitle: title, anchor: frag)
                case .source: store.selectSource(byDisplayName: title, anchor: frag)
                case nil:     break
                }
                return .handled
            })
            .task(id: markdown) {
                // Display is rendered synchronously in `body`; this task only
                // derives the anchor block list (post-layout) and consumes any
                // pending scroll anchor set by selectPage/Source.
                blocks = AnchorBlock.parse(renderMarkdown(markdown))
                if let frag = store.consumePendingScrollAnchor(for: currentSelection),
                   let id = resolveAnchor(frag, in: blocks) {
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    /// Reset the paragraph counter and return the rendered markdown, together,
    /// so both run in `body` before `StructuredText`'s layout pass consumes the
    /// counter. (A bare `resetCounter()` statement isn't valid inside a
    /// `@ViewBuilder`, so it's bundled into this one-call helper.)
    @MainActor
    private func renderNumbered(_ raw: String) -> String {
        NumberedParagraphStyle.resetCounter()
        return renderMarkdown(raw)
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
