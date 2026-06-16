import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the pure HTML → Markdown converter. Covers headings, links, emphasis,
/// lists (incl. nested + ordered), code/pre, blockquotes, images, entity decoding,
/// title extraction, content scoping (script/style/nav stripping, article/main/body),
/// whitespace handling, and tolerance to malformed / unclosed / empty input.
struct HTMLToMarkdownTests {

    private func md(_ html: String) -> String { HTMLToMarkdown.markdown(from: html) }

    // MARK: - Headings

    @Test func headingsMapToHashes() {
        #expect(md("<h1>Title</h1>") == "# Title")
        #expect(md("<h2>Sub</h2>") == "## Sub")
        #expect(md("<h6>Deep</h6>") == "###### Deep")
    }

    @Test func headingAndParagraphSeparateWithBlankLine() {
        let out = md("<h1>Title</h1><p>Body text.</p>")
        #expect(out == "# Title\n\nBody text.")
    }

    // MARK: - Paragraphs / br

    @Test func paragraphsBecomeBlankLineSeparated() {
        let out = md("<p>One</p><p>Two</p>")
        #expect(out == "One\n\nTwo")
    }

    @Test func brBecomesNewline() {
        let out = md("<p>Line one<br>Line two</p>")
        #expect(out == "Line one\nLine two")
    }

    // MARK: - Links

    @Test func anchorBecomesMarkdownLink() {
        #expect(md(#"<a href="https://x.com">click</a>"#) == "[click](https://x.com)")
    }

    @Test func anchorInsideParagraph() {
        let out = md(#"<p>See <a href="https://x.com">the site</a> now.</p>"#)
        #expect(out == "See [the site](https://x.com) now.")
    }

    @Test func anchorWithEmptyHrefDegradesToText() {
        #expect(md("<a>bare</a>") == "bare")
    }

    // MARK: - Emphasis

    @Test func strongAndBoldBecomeDoubleStar() {
        #expect(md("<strong>x</strong>") == "**x**")
        #expect(md("<b>y</b>") == "**y**")
    }

    @Test func emAndItalicBecomeSingleStar() {
        #expect(md("<em>x</em>") == "*x*")
        #expect(md("<i>y</i>") == "*y*")
    }

    @Test func nestedEmphasis() {
        #expect(md("<p><strong>bold <em>and italic</em></strong></p>") == "**bold *and italic***")
    }

    // MARK: - Code / pre

    @Test func inlineCodeBecomesBackticks() {
        #expect(md("<p>Use <code>print()</code> here.</p>") == "Use `print()` here.")
    }

    @Test func inlineCodePreservesAngleBrackets() {
        // Entities inside code decode but are not re-interpreted as tags.
        #expect(md("<code>a &lt; b</code>") == "`a < b`")
    }

    @Test func preBecomesFencedBlock() {
        let out = md("<pre>let x = 1\nlet y = 2</pre>")
        #expect(out == "```\nlet x = 1\nlet y = 2\n```")
    }

    // MARK: - Lists

    @Test func unorderedListBecomesDashes() {
        let out = md("<ul><li>apple</li><li>pear</li></ul>")
        #expect(out == "- apple\n\n- pear")
    }

    @Test func orderedListBecomesNumbers() {
        let out = md("<ol><li>first</li><li>second</li></ol>")
        #expect(out == "1. first\n\n2. second")
    }

    @Test func nestedListIndents() {
        let out = md("<ul><li>a<ul><li>a1</li></ul></li><li>b</li></ul>")
        // The nested item is indented two spaces.
        #expect(out.contains("- a"))
        #expect(out.contains("  - a1"))
        #expect(out.contains("- b"))
    }

    // MARK: - Blockquote

    @Test func blockquoteBecomesAngleBracket() {
        #expect(md("<blockquote><p>quoted</p></blockquote>") == "> quoted")
    }

    // MARK: - Images

    @Test func imageBecomesMarkdownImage() {
        #expect(md(#"<img src="/a.png" alt="a cat">"#) == "![a cat](/a.png)")
    }

    @Test func imageWithoutAltStillRenders() {
        #expect(md(#"<img src="/a.png">"#) == "![](/a.png)")
    }

    // MARK: - Entities

    @Test func namedEntitiesDecode() {
        #expect(md("<p>a &amp; b &lt; c &gt; d</p>") == "a & b < c > d")
        #expect(md("<p>&quot;hi&quot; it&#39;s</p>") == "\"hi\" it's")
    }

    @Test func nbspBecomesNonBreakingSpace() {
        // &nbsp; decodes to U+00A0, which collapseWhitespace treats as a space.
        #expect(md("<p>a&nbsp;b</p>") == "a b")
    }

    @Test func numericEntitiesDecimalAndHex() {
        #expect(md("<p>&#65;&#66;&#67;</p>") == "ABC")
        #expect(md("<p>&#x41;&#x42;</p>") == "AB")
    }

    @Test func unknownEntityLeftLiteral() {
        #expect(md("<p>r&dno;m</p>") == "r&dno;m")
        #expect(md("<p>tom & jerry</p>") == "tom & jerry")
    }

    // MARK: - Whitespace

    @Test func runsOfWhitespaceCollapse() {
        #expect(md("<p>a   b\n\tc</p>") == "a b c")
    }

    @Test func leadingAndTrailingWhitespaceTrimmed() {
        #expect(md("   <p>  hello  </p>   ") == "hello")
    }

    // MARK: - Content scoping

    @Test func scriptAndStyleStripped() {
        let html = "<p>keep</p><script>var x = 1;</script><style>.a{}</style><p>also</p>"
        #expect(md(html) == "keep\n\nalso")
    }

    @Test func navAndFooterStripped() {
        let html = "<nav>menu links</nav><p>content</p><footer>copyright</footer>"
        #expect(md(html) == "content")
    }

    @Test func headStripped() {
        let html = "<head><title>T</title><meta></head><body><p>visible</p></body>"
        #expect(md(html) == "visible")
    }

    @Test func articlePreferredOverSurroundingChrome() {
        let html = """
        <body><nav>nav</nav><article><h1>Real</h1><p>Body</p></article><aside>ad</aside></body>
        """
        #expect(md(html) == "# Real\n\nBody")
    }

    @Test func mainUsedWhenNoArticle() {
        let html = "<body><header>chrome</header><main><p>core</p></main></body>"
        #expect(md(html) == "core")
    }

    @Test func scriptInsideArticleRemoved() {
        let html = "<article><p>text</p><script>evil()</script></article>"
        #expect(md(html) == "text")
    }

    // MARK: - Title extraction

    @Test func titleExtracted() {
        let r = HTMLToMarkdown.convert("<html><head><title>My Page</title></head><body><p>x</p></body></html>")
        #expect(r.title == "My Page")
    }

    @Test func titleEntityDecodedAndCollapsed() {
        let r = HTMLToMarkdown.convert("<title>Tom &amp; Jerry  &mdash;  Show</title>")
        #expect(r.title == "Tom & Jerry — Show")
    }

    @Test func titleNilWhenAbsent() {
        let r = HTMLToMarkdown.convert("<p>no title here</p>")
        #expect(r.title == nil)
    }

    @Test func emptyTitleIsNil() {
        let r = HTMLToMarkdown.convert("<title>   </title><p>x</p>")
        #expect(r.title == nil)
    }

    // MARK: - Tolerance / malformed

    @Test func emptyInputYieldsEmpty() {
        let r = HTMLToMarkdown.convert("")
        #expect(r.markdown == "")
        #expect(r.title == nil)
    }

    @Test func unclosedTagsDoNotCrash() {
        // Missing </p>, </strong>; must not loop or throw.
        let out = md("<p>start <strong>bold text <em>and more")
        #expect(out.contains("start"))
        #expect(out.contains("bold text"))
    }

    @Test func strayCloseTagsIgnored() {
        #expect(md("</div></p>plain text</ul>") == "plain text")
    }

    @Test func unterminatedTagTreatedAsText() {
        // A '<' with no '>' — emitted literally, not swallowed.
        let out = md("<p>a < b and c</p>")
        #expect(out.contains("a < b and c"))
    }

    @Test func commentsStripped() {
        #expect(md("<p>before<!-- hidden comment -->after</p>") == "beforeafter")
    }

    @Test func doctypeIgnored() {
        let out = md("<!DOCTYPE html><html><body><p>doc</p></body></html>")
        #expect(out == "doc")
    }

    @Test func attributesWithAngleBracketInQuotesParse() {
        // A '>' inside a quoted attribute must not close the tag early.
        let out = md(#"<a href="https://x.com/a?b=1&amp;c=2" title="a > b">link</a>"#)
        #expect(out == "[link](https://x.com/a?b=1&c=2)")
    }

    @Test func plainTextWithNoTags() {
        #expect(md("just some plain text") == "just some plain text")
    }

    @Test func divsBecomeParagraphBreaks() {
        #expect(md("<div>one</div><div>two</div>") == "one\n\ntwo")
    }

    @Test func realisticDocumentConverts() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Photosynthesis</title><style>body{margin:0}</style></head>
        <body>
          <nav><a href="/">Home</a></nav>
          <article>
            <h1>Photosynthesis</h1>
            <p>Plants convert <strong>light</strong> into <em>energy</em>.</p>
            <h2>Steps</h2>
            <ul>
              <li>Light reactions</li>
              <li>Calvin cycle</li>
            </ul>
            <p>See <a href="https://en.wikipedia.org/wiki/Calvin_cycle">the Calvin cycle</a>.</p>
          </article>
          <footer>&copy; 2026</footer>
        </body>
        </html>
        """
        let r = HTMLToMarkdown.convert(html)
        #expect(r.title == "Photosynthesis")
        let m = r.markdown
        #expect(m.hasPrefix("# Photosynthesis"))
        #expect(m.contains("Plants convert **light** into *energy*."))
        #expect(m.contains("## Steps"))
        #expect(m.contains("- Light reactions"))
        #expect(m.contains("- Calvin cycle"))
        #expect(m.contains("[the Calvin cycle](https://en.wikipedia.org/wiki/Calvin_cycle)"))
        #expect(!m.contains("Home"))     // nav stripped
        #expect(!m.contains("2026"))     // footer stripped
        #expect(!m.contains("margin"))   // style stripped
    }
}
