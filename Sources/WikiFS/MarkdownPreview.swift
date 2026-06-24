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
///
/// Quote highlighting: a `[[source:Name#"quote"]]` or `[[Page#"quote"]]` link
/// sets `highlightQuote` via the scroll-anchor consume path, and
/// `WikiLinkStylingParser` applies `.backgroundColor` to the matched substring.
///
/// Scrolling is driven by `highlightVersion`: the `.task` consumes the anchor
/// and stashes the target + bumps the version; `.onChange(of: highlightVersion)`
/// scrolls with a *current* `ScrollViewProxy` after the view hierarchy settles.
/// Trailing newlines keyed to the version force `StructuredText` to re-parse
/// without changing its structural identity, so the proxy stays valid.
struct MarkdownPreview: View {
    @Bindable var store: WikiStoreModel
    let markdown: String
    var contentInset: Bool = true
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    /// The current selection this preview is rendering (page id or source id).
    /// Used to match against `store.pendingScrollAnchor`.
    var currentSelection: WikiSelection? = nil
    /// The File Provider spike, for "Copy File Path" on wiki links. Only page
    /// previews (which own a spike) pass it; `nil` elsewhere omits that item.
    var fileProvider: FileProviderSpike? = nil

    @State private var blocks: [AnchorBlock] = []
    /// The quote to highlight, set after consuming a `pendingScrollAnchor` with
    /// a `#"quoted passage"` fragment. Nil when there's no active highlight.
    @State private var highlightQuote: String?
    /// Bumped each time `highlightQuote` changes. Used in the versioned markup
    /// to force `StructuredText` to re-parse without changing its view identity.
    @State private var highlightVersion: Int = 0
    /// Opens the "Add from URL" sheet pre-filled with a URL — injected by
    /// `ContentView` so the right-click "Add as Source" item works in every
    /// reader (pages, sources, system prompt, changelog) without per-view wiring.
    @Environment(\.addURLHandler) private var addURLHandler

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        let rendered = ReaderTiming.measure("reader.preprocess") {
                            renderNumbered(markdown)
                        }
                        // Append trailing newlines keyed to highlightVersion so
                        // StructuredText sees a markup change and re-parses with
                        // the current parser, without changing view identity.
                        let versioned = highlightVersion > 0
                            ? rendered + String(repeating: "\n", count: highlightVersion)
                            : rendered
                        StructuredText(versioned, parser: WikiLinkStylingParser(highlightQuote: highlightQuote))
                            .textual.paragraphStyle(NumberedParagraphStyle())
                            .textual.textSelection(.enabled)
                            .textual.fontScale(CGFloat(readerZoom))
                            .textual.linkContextMenu { url in
                                WikiLinkContextMenu.items(for: url, store: store, fileProvider: fileProvider, addURL: addURLHandler)
                            }
                            .textual.inlineStyle(InlineStyle.default.link())
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
            .task(id: RenderKey(markdown: markdown, anchorVersion: store.pendingScrollAnchorVersion)) {
                // Parse the RAW markdown, not renderMarkdown(markdown): anchors
                // only walk heading/paragraph structure, which footnote expansion
                // and linkification don't change. Re-running both preprocessing
                // passes here duplicated the body's work over the full document —
                // a real cost on 500KB+ sources. Footnote definitions (`[^n]:`)
                // and the appended footnote section are skipped by AnchorBlock,
                // so block count/order is identical to the rendered path.
                blocks = AnchorBlock.parse(markdown)
                if let frag = store.consumePendingScrollAnchor(for: currentSelection),
                   let id = resolveAnchor(frag, in: blocks) {
                    let quote = frag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    // Scroll first — while the view hierarchy is stable and the
                    // proxy is guaranteed valid. Then set the highlight state
                    // which triggers StructuredText to re-parse via the versioned
                    // markup. Scroll before state change is load-bearing.
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(id, anchor: .top)
                    highlightQuote = quote.wikiNormalized
                    highlightVersion += 1
                }
            }
            .onChange(of: markdown) {
                highlightQuote = nil
                highlightVersion = 0
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
        // Shared footnote-expand + wiki-link-linkify pre-pass (see
        // ReaderMarkdown); the native reader passes the store's existence
        // checks so missing links are styled as ghosts.
        ReaderMarkdown.prepared(raw) { [weak store] name, kind in
            kind == .source ? store?.sourceExists(displayName: name) ?? false : store?.pageExists(title: name) ?? false
        }
    }
}

/// Keys the `MarkdownPreview` consume task so it re-fires on repeat quote clicks
/// to the already-open document (same markdown, bumped anchor version).
private struct RenderKey: Hashable {
    let markdown: String
    let anchorVersion: Int
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
