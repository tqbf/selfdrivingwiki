import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Fidelity tests for the source web reader's Markdown→HTML renderer. The
/// renderer receives RAW markdown (wiki links + footnotes are pre-processed into
/// ordinary markdown links before it runs — see SourceWebView's pre-pass), so
/// these feed standard Markdown and assert the HTML structure.
struct MarkdownHTMLRendererTests {

    @Test func headingWithSlug() {
        #expect(MarkdownHTMLRenderer.render("# Hello") == "<h1 id=\"hello\">Hello</h1>")
    }

    @Test func headingSlugLowercasesAndDashes() {
        #expect(MarkdownHTMLRenderer.render("## My Section") == "<h2 id=\"my-section\">My Section</h2>")
    }

    @Test func paragraphWithInline() {
        let html = MarkdownHTMLRenderer.render("This is **bold** and *italic*.")
        #expect(html == "<p>This is <strong>bold</strong> and <em>italic</em>.</p>")
    }

    @Test func strikethrough() {
        #expect(MarkdownHTMLRenderer.render("~~done~~") == "<p><del>done</del></p>")
    }

    @Test func inlineCode() {
        let html = MarkdownHTMLRenderer.render("Use `swift build` now.")
        #expect(html == "<p>Use <code>swift build</code> now.</p>")
    }

    @Test func fencedCodeBlockWithLanguage() {
        let md = "```swift\nlet x = 1\n```"
        let html = MarkdownHTMLRenderer.render(md)
        // cmark keeps the trailing newline in the code content.
        #expect(html == "<pre><code class=\"language-swift\">let x = 1\n</code></pre>")
    }

    @Test func regularLink() {
        let html = MarkdownHTMLRenderer.render("[ex](https://example.com)")
        #expect(html == "<p><a href=\"https://example.com\" title=\"https://example.com\">ex</a></p>")
    }

    @Test func wikiLinkHrefPassesThrough() {
        // After the pre-pass, a wiki link is an ordinary markdown link with a
        // wiki:// destination. The renderer must pass it through verbatim so the
        // navigation delegate can route it.
        let html = MarkdownHTMLRenderer.render("[Page](wiki://page/Page)")
        #expect(html == "<p><a href=\"wiki://page/Page\" title=\"wiki://page/Page\">Page</a></p>")
    }

    @Test func unorderedList() {
        let html = MarkdownHTMLRenderer.render("- a\n- b")
        #expect(html == "<ul><li>a</li><li>b</li></ul>")
    }

    @Test func orderedList() {
        let html = MarkdownHTMLRenderer.render("1. one\n2. two")
        #expect(html == "<ol><li>one</li><li>two</li></ol>")
    }

    @Test func blockquote() {
        let html = MarkdownHTMLRenderer.render("> quote")
        #expect(html == "<blockquote><p>quote</p></blockquote>")
    }

    @Test func thematicBreak() {
        #expect(MarkdownHTMLRenderer.render("---") == "<hr>")
    }

    @Test func escapesHTMLSpecialCharacters() {
        let html = MarkdownHTMLRenderer.render("a < b > c & d")
        #expect(html == "<p>a &lt; b &gt; c &amp; d</p>")
    }

    @Test func tableRendersHeaderAndBody() {
        let md = """
        | A   | B   |
        | --- | --- |
        | 1   | 2   |
        """
        let html = MarkdownHTMLRenderer.render(md)
        #expect(html == "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>")
    }

    @Test func headingSlugDedupMatchesAnchorBlock() {
        // Duplicate headings must dedup the same way AnchorBlock.makeSlug does,
        // so #fragment resolution stays consistent between the two readers.
        let html = MarkdownHTMLRenderer.render("# Overview\n\n# Overview")
        #expect(html == "<h1 id=\"overview\">Overview</h1><h1 id=\"overview-1\">Overview</h1>")
    }

    // MARK: Mermaid

    @Test func mermaidFenceEmitsLanguageClassAndEscaping() {
        // The mermaid bootstrap depends on visitCodeBlock emitting the exact
        // `class="language-mermaid"` and HTML-escaping the body (so textContent
        // un-escapes it back to the diagram source). Uses `contains` rather than
        // == because cmark keeps the trailing newline in fenced code.
        let html = MarkdownHTMLRenderer.render("```mermaid\ngraph TD\nA-->B\n```")
        #expect(html.contains(#"class="language-mermaid""#))
        #expect(html.contains("A--&gt;B"))   // escape(): > → &gt;
    }

    @Test func documentHTMLEmbedsNoScriptWhenLibAbsent() {
        // Under `swift test` there's no .app bundle, so `mermaidLib` is nil →
        // documentHTML embeds NO <script>, and the mermaid block is preserved as
        // ordinary code. Pins graceful degradation (AC.4/AC.5).
        let h = WikiReaderView.documentHTML("<pre><code class=\"language-mermaid\">graph TD</code></pre>")
        #expect(!h.contains("<script>"))
        #expect(h.contains(#"class="language-mermaid""#))
    }

    // MARK: - Inline HTML passthrough (Phase 4a embeds)

    @Test func rawInlineHTMLFromEmbedSurvivesRender() {
        // The embed pre-pass emits raw inline HTML (e.g. `<img src="wiki-blob://…">`).
        // swift-markdown parses it as InlineHTML, and the renderer must pass it
        // through verbatim — otherwise the embed is silently dropped. This test
        // guards against someone removing visitInlineHTML/visitHTMLBlock.
        let id = PageID(rawValue: "01HTESTRENDER0000000000001")
        let prepared = WikiLinkMarkdown.linkified(
            "Here is ![[source:img.png]] inline.",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "image/png") }
        )
        let html = MarkdownHTMLRenderer.render(prepared)
        #expect(html.contains(#"<img src="wiki-blob://source/\#(id.rawValue)""#))
        #expect(html.contains("wiki-embed"))
    }

    // MARK: - Mermaid embed survives the markdown→HTML pipeline (#736).

    /// A `.mmd` source embed (`![[source:diagram.mmd]]`) must survive the
    /// reader's `MarkdownHTMLRenderer` as a single intact
    /// `<pre><code class="language-mermaid">…</code></pre>` whose
    /// `textContent` CSS-decodes back to the original diagram source —
    /// otherwise the reader's `mermaidBootstrapJS` reads garbled
    /// `code.textContent` and `mermaid.parse()` fails with
    /// "Syntax error in text". This checks the four contexts that broke the
    /// previous raw-`<div>` emit: paragraph surrounds, a blank line inside
    /// the diagram, the embed inside a list item, and the embed mid-paragraph.
    @Test func mermaidEmbedSurvivesMarkdownRendererInAllContexts() {
        let id = PageID(rawValue: "01HTESTMERMAID0000000000001")
        let cases: [(String, String, String)] = [
            ("paragraph-surround",
             "intro.\n\n![[source:diagram.mmd]]\n\noutro.",
             "graph TD\n    A --> B\n    B --> C\n"),
            ("blank-line-in-diagram",
             "intro.\n\n![[source:diagram.mmd]]\n\noutro.",
             "graph TD\n    A --> B\n\n    B --> C\n"),
            ("inside-list",
             "- before\n- ![[source:diagram.mmd]]\n- after",
             "graph TD\n    A --> B\n    B --> C\n"),
            ("mid-paragraph",
             "text ![[source:diagram.mmd]] more text",
             "graph TD\n    A --> B\n    B --> C\n"),
        ]
        for (label, body, diagramSource) in cases {
            let prepared = WikiLinkMarkdown.linkified(
                body,
                isResolved: { _, _ in true },
                embedInfo: { _ in
                    WikiLinkMarkdown.SourceEmbedInfo(
                        id: id, mimeType: MimeType.mermaid,
                        target: EmbedTarget(
                            kind: .diagram,
                            url: "wiki://source/\(id.rawValue)",
                            content: diagramSource)
                    )
                }
            )
            let html = MarkdownHTMLRenderer.render(prepared)
            // Exactly one mermaid code element survives.
            let mermaidCount = html.components(
                separatedBy: "class=\"language-mermaid\"").count - 1
            #expect(mermaidCount == 1,
                    "\(label): expected one `<code class=\"language-mermaid\">`, got \(mermaidCount). HTML:\n\(html)")
            // visitCodeBlock escapes `>` exactly ONCE → `&gt;`. The previous
            // raw-div path double-escaped to `&amp;gt;` (literal `&gt;`) in
            // some contexts, tripping mermaid's parser.
            #expect(html.contains("A --&gt; B"),
                    "\(label): expected `A --&gt; B` in HTML:\n\(html)")
            #expect(!html.contains("&amp;gt;"),
                    "\(label): double-escaped `&amp;gt;` (literal `&gt;`) in HTML:\n\(html)")
            // The diagram text is NOT wrapped in `<p>` tags by the markdown
            // converter — it flows into the `<pre><code>` unchanged.
            #expect(!html.contains("<p>graph TD"),
                    "\(label): diagram body wrapped in `<p>`. HTML:\n\(html)")
            // The `<pre>` wraps the `<code>` — no orphaned fragments.
            #expect(html.contains("<pre><code class=\"language-mermaid\">"),
                    "\(label): missing `<pre><code class=\"language-mermaid\">`. HTML:\n\(html)")
        }
    }

    /// Mermaid source containing a ``` triple-backtick run (rare, but
    /// possible in node labels) must not prematurely close the fence we
    /// emit: we pick a fence length strictly longer than any run in the
    /// diagram body (CommonMark §4.5).
    @Test func mermaidEmbedWithBackticksInSourceUsesLongerFence() {
        let id = PageID(rawValue: "01HTESTMERMAID0000000000002")
        let diagram = "graph TD\n    A[\"has ``` triple backticks\"] --> B"
        let prepared = WikiLinkMarkdown.linkified(
            "![[source:diagram.mmd]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(
                    id: id, mimeType: MimeType.mermaid,
                    target: EmbedTarget(
                        kind: .diagram,
                        url: "wiki://source/\(id.rawValue)", content: diagram)
                )
            }
        )
        let html = MarkdownHTMLRenderer.render(prepared)
        // The 3-backtick run inside the body is preserved verbatim, AND the
        // outer fence (4+ backticks) keeps the block intact.
        #expect(html.contains("\"has ``` triple backticks\""))
        #expect(html.contains("class=\"language-mermaid\""))
        // No premature close → only one code element.
        let count = html.components(
            separatedBy: "class=\"language-mermaid\"").count - 1
        #expect(count == 1)
    }
}
