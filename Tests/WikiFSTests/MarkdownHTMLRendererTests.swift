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

    @Test func mermaidBlockRendersMermaidContainer() {
        // ```mermaid fences must produce <pre class="mermaid"> so the WKWebView
        // mermaid runtime can find and render them via the .mermaid class hook.
        let md = "```mermaid\ngraph TD\n    A --> B\n```"
        let html = MarkdownHTMLRenderer.render(md)
        #expect(html == "<pre class=\"mermaid\">graph TD\n    A --&gt; B\n</pre>")
        #expect(!html.contains("<code"))
    }

    @Test func mermaidBlockEscapesSpecialCharacters() {
        // Mermaid reads decoded textContent — the browser decodes entities back
        // before mermaid sees them. Keep escaping so raw < > & in diagram source
        // don't break the surrounding HTML document.
        let md = "```mermaid\nA --> B & <x>\n```"
        let html = MarkdownHTMLRenderer.render(md)
        #expect(html.contains("&amp;"))
        #expect(html.contains("&lt;"))
        #expect(html.contains("&gt;"))
        #expect(!html.contains("<code"))
    }

    @Test func fencedCodeBlockNoLanguage() {
        // A fence with no language tag must still render the generic <pre><code>
        // wrapper (no class attribute).
        let md = "```\nsome code\n```"
        let html = MarkdownHTMLRenderer.render(md)
        #expect(html == "<pre><code>some code\n</code></pre>")
    }

    @Test func mermaidFenceIsCaseSensitive() {
        // The mermaid hook is keyed on the exact lowercase `mermaid` info string
        // (the canonical fence tag). A case variant must fall through to the
        // ordinary highlighted-code path, not the diagram container.
        let html = MarkdownHTMLRenderer.render("```Mermaid\ngraph TD\n```")
        #expect(html == "<pre><code class=\"language-Mermaid\">graph TD\n</code></pre>")
        #expect(!html.contains("class=\"mermaid\""))
    }

    @Test func emptyMermaidBlock() {
        // An empty diagram fence is harmless: it yields a valid empty container
        // (mermaid simply finds nothing to render).
        let html = MarkdownHTMLRenderer.render("```mermaid\n```")
        #expect(html == "<pre class=\"mermaid\"></pre>")
    }
}
