import Testing
@testable import WikiFS

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
        #expect(html == "<p><a href=\"https://example.com\">ex</a></p>")
    }

    @Test func wikiLinkHrefPassesThrough() {
        // After the pre-pass, a wiki link is an ordinary markdown link with a
        // wiki:// destination. The renderer must pass it through verbatim so the
        // navigation delegate can route it.
        let html = MarkdownHTMLRenderer.render("[Page](wiki://page/Page)")
        #expect(html == "<p><a href=\"wiki://page/Page\">Page</a></p>")
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
}
