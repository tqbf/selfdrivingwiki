import Foundation
import Markdown
import WikiFSCore

/// Renders Markdown → HTML for the source web reader (the `WKWebView` path).
/// Walks a swift-markdown `Document` with a `MarkupVisitor`, emitting faithful
/// HTML for the GFM constructs large sources use: headings (with GFM-slug `id`s
/// matching `AnchorBlock.makeSlug`, so `#fragment` anchors resolve the same as
/// the native reader), paragraphs, emphasis/strong/strikethrough, inline +
/// fenced code, links + images, ordered/unordered lists, blockquotes, thematic
/// breaks, and tables.
///
/// Wiki links and footnotes arrive already pre-processed into ordinary markdown
/// links by `WikiReaderView`'s pre-pass (`WikiFootnoteMarkdown` +
/// `WikiLinkMarkdown` — the same transforms the native reader uses), so they
/// need no special handling here.
///
/// Pure / thread-safe: the render runs off the main actor.
struct MarkdownHTMLRenderer: MarkupVisitor {

    /// Render `markdown` to an HTML fragment (no `<html>`/`<body>` wrapper —
    /// `WikiReaderView.documentHTML` wraps it).
    ///
    /// When `imageResolver` is provided, relative image srcs (those that are not
    /// `http(s)`, `data:`, or already `wiki-blob:`/`wiki:`) are passed to it; a
    /// non-nil return rewrites the `<img src>`. Absolute/protocol/data srcs and
    /// unresolved relatives are left verbatim. Phase 4 sibling resolution.
    static func render(
        _ markdown: String,
        imageResolver: ((String) -> String?)? = nil
    ) -> String {
        var renderer = MarkdownHTMLRenderer()
        renderer.imageResolver = imageResolver
        return renderer.visit(Document(parsing: markdown))
    }

    /// Per-render slug dedup counts, mirroring `AnchorBlock.makeSlug` so heading
    /// ids match the native reader's resolution list.
    private var slugCounts: [String: Int] = [:]

    /// Phase 4: optional resolver that rewrites a relative image src to a
    /// `wiki-blob://source/<id>` URL. Set by the static `render` before visiting.
    private var imageResolver: ((String) -> String?)?

    private mutating func visitChildren(_ markup: Markup) -> String {
        var s = ""
        for child in markup.children { s += visit(child) }
        return s
    }

    /// Fallback for nodes we don't specialize (Document, BlockDirective, …):
    /// descend into children.
    mutating func defaultVisit(_ markup: Markup) -> String { visitChildren(markup) }

    // MARK: Block

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = max(1, min(6, heading.level))
        let slug = AnchorBlock.makeSlug(plainText(heading), counts: &slugCounts)
        return "<h\(level) id=\"\(escapeAttribute(slug))\">\(visitChildren(heading))</h\(level)>"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(visitChildren(paragraph))</p>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(visitChildren(blockQuote))</blockquote>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let cls = (codeBlock.language ?? "").isEmpty
            ? ""
            : " class=\"language-\(escapeAttribute(codeBlock.language ?? ""))\""
        return "<pre><code\(cls)>\(escape(codeBlock.code))</code></pre>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>" }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { html.rawHTML }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\(visitChildren(unorderedList))</ul>"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let start = orderedList.startIndex
        let attr = start <= 1 ? "" : " start=\"\(start)\""
        return "<ol\(attr)>\(visitChildren(orderedList))</ol>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // Tight-list heuristic: a single-paragraph item renders without the <p>
        // wrapper (how readers render tight lists). Multi-block items (loose
        // lists, nested lists, blockquotes) keep their block structure.
        let kids = Array(listItem.children)
        if kids.count == 1, let only = kids.first as? Paragraph {
            return "<li>\(visitChildren(only))</li>"
        }
        return "<li>\(visitChildren(listItem))</li>"
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String { escape(text.string) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String { "<code>\(escape(inlineCode.code))</code>" }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { "<em>\(visitChildren(emphasis))</em>" }
    mutating func visitStrong(_ strong: Strong) -> String { "<strong>\(visitChildren(strong))</strong>" }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String { "<del>\(visitChildren(strikethrough))</del>" }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { " " }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>" }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String { inlineHTML.rawHTML }

    mutating func visitLink(_ link: Link) -> String {
        let dest = link.destination ?? ""
        var tooltip = dest
        if let url = URL(string: dest), url.scheme == WikiLinkMarkdown.scheme {
            if url.host == "anchor" {
                if let frag = WikiLinkMarkdown.fragment(from: url) {
                    tooltip = "#\(frag)"
                }
            } else if let title = WikiLinkMarkdown.target(from: url) {
                let prefix = url.host == "source" ? "source:" : ""
                let frag = WikiLinkMarkdown.fragment(from: url)
                let fragSuffix = frag.map { "#\($0)" } ?? ""
                tooltip = "[[\(prefix)\(title)\(fragSuffix)]]"
            }
        }
        return "<a href=\"\(escapeAttribute(dest))\" title=\"\(escapeAttribute(tooltip))\">\(visitChildren(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let rawSrc = image.source ?? ""
        let src = resolvedImageSrc(rawSrc)
        return "<img src=\"\(escapeAttribute(src))\" alt=\"\(escape(plainText(image)))\">"
    }

    /// Phase 4: resolve a relative image src through the `imageResolver` (when
    /// present). Only relative srcs are candidates — absolute (`http`/`https`),
    /// `data:`, and already-rewritten (`wiki-blob:`/`wiki:`) srcs pass through
    /// verbatim. An unresolved relative is left verbatim (no crash).
    private func resolvedImageSrc(_ src: String) -> String {
        guard let resolver = imageResolver, !src.isEmpty else { return src }
        let lower = src.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("data:")
            || lower.hasPrefix("wiki-blob:") || lower.hasPrefix("wiki:") {
            return src
        }
        return resolver(src) ?? src
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String { "<table>\(visitChildren(table))</table>" }
    // swift-markdown models Table.Head as containing cells directly (no Row), so
    // the head needs its own <tr>; body rows come through visitTableRow.
    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        "<thead><tr>\(visitChildren(tableHead))</tr></thead>"
    }
    mutating func visitTableBody(_ tableBody: Table.Body) -> String { "<tbody>\(visitChildren(tableBody))</tbody>" }
    mutating func visitTableRow(_ tableRow: Table.Row) -> String { "<tr>\(visitChildren(tableRow))</tr>" }
    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        let tag = (tableCell.parent is Table.Head) ? "th" : "td"
        return "<\(tag)>\(visitChildren(tableCell))</\(tag)>"
    }

    // MARK: Helpers

    /// Plain text of a subtree — for heading slugs and image alt. Recurses into
    /// links/images to capture display / alt text.
    private func plainText(_ markup: Markup) -> String {
        var s = ""
        for child in markup.children {
            if let t = child as? Text { s += t.string }
            else if child is SoftBreak || child is LineBreak { s += " " }
            else { s += plainText(child) }
        }
        return s
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
