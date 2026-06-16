import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the pure `[[wiki-link]]` → Markdown-link transform that powers
/// the in-app preview. No view, no store: resolution is injected as a closure.
struct WikiLinkMarkdownTests {

    // MARK: - Basic forms

    @Test func simpleLinkBecomesMarkdownLink() {
        let out = WikiLinkMarkdown.linkified("See [[Home]] now.")
        #expect(out == "See [Home](wiki://page?title=Home) now.")
    }

    @Test func aliasedLinkUsesAliasTextAndTargetURL() {
        let out = WikiLinkMarkdown.linkified("See [[Calvin Cycle|the cycle]].")
        #expect(out == "See [the cycle](wiki://page?title=Calvin%20Cycle).")
    }

    @Test func multipleLinksInOneBody() {
        let out = WikiLinkMarkdown.linkified("[[Alpha]] and [[Beta|B]] and [[Gamma]]")
        #expect(out == "[Alpha](wiki://page?title=Alpha) and "
            + "[B](wiki://page?title=Beta) and "
            + "[Gamma](wiki://page?title=Gamma)")
    }

    @Test func duplicateTargetsAreEachRewrittenInPlace() {
        // Unlike WikiLinkParser (which de-dupes for the graph), the transform must
        // rewrite EVERY occurrence so all of them are clickable in the preview.
        let out = WikiLinkMarkdown.linkified("[[Home]] then [[Home]] again")
        #expect(out == "[Home](wiki://page?title=Home) then "
            + "[Home](wiki://page?title=Home) again")
    }

    // MARK: - URL encoding

    @Test func spacesInTitleArePercentEncoded() {
        let out = WikiLinkMarkdown.linkified("[[Photosynthesis Overview]]")
        #expect(out == "[Photosynthesis Overview](wiki://page?title=Photosynthesis%20Overview)")
    }

    @Test func queryMetacharactersInTitleAreEncoded() {
        // &, =, ?, #, + must not leak into the query as separators.
        let out = WikiLinkMarkdown.linkified("[[A&B=C?D#E+F]]")
        let title = WikiLinkMarkdown.target(from: URL(string: extractURL(out))!)
        #expect(title == "A&B=C?D#E+F")
    }

    @Test func whitespaceInTargetIsCollapsedLikeTheParser() {
        let out = WikiLinkMarkdown.linkified("[[  Home   Page  ]]")
        #expect(out == "[Home Page](wiki://page?title=Home%20Page)")
    }

    // MARK: - Resolution / styling host

    @Test func unresolvedTargetUsesMissingHost() {
        let out = WikiLinkMarkdown.linkified("[[Ghost]]") { _ in false }
        #expect(out == "[Ghost](wiki://missing?title=Ghost)")
    }

    @Test func mixedResolutionPicksHostPerLink() {
        let out = WikiLinkMarkdown.linkified("[[Real]] vs [[Fake]]") { $0 == "Real" }
        #expect(out == "[Real](wiki://page?title=Real) vs "
            + "[Fake](wiki://missing?title=Fake)")
    }

    // MARK: - Code-span / fence protection

    @Test func inlineCodeSpanIsNotLinkified() {
        let out = WikiLinkMarkdown.linkified("Use `[[Home]]` literally, but [[Home]] links.")
        #expect(out == "Use `[[Home]]` literally, but [Home](wiki://page?title=Home) links.")
    }

    @Test func fencedCodeBlockIsNotLinkified() {
        let body = """
        Before [[Real]]

        ```
        code with [[NotALink]] inside
        ```

        After [[Also]]
        """
        let out = WikiLinkMarkdown.linkified(body)
        #expect(out.contains("[Real](wiki://page?title=Real)"))
        #expect(out.contains("[Also](wiki://page?title=Also)"))
        // The fenced content stays verbatim.
        #expect(out.contains("code with [[NotALink]] inside"))
        #expect(!out.contains("NotALink](wiki"))
    }

    @Test func doubleBacktickSpanProtectsSingleBacktickInside() {
        let out = WikiLinkMarkdown.linkified("``[[A]] `tick` [[B]]`` and [[C]]")
        // Everything inside the `` … `` span is literal; only [[C]] links.
        #expect(out.contains("``[[A]] `tick` [[B]]``"))
        #expect(out.contains("[C](wiki://page?title=C)"))
        #expect(!out.contains("[A](wiki"))
        #expect(!out.contains("[B](wiki"))
    }

    // MARK: - Edge cases

    @Test func emptyTargetIsLeftLiteral() {
        #expect(WikiLinkMarkdown.linkified("[[]] and [[   ]]") == "[[]] and [[   ]]")
    }

    @Test func bodyWithoutLinksIsUnchanged() {
        let body = "Plain **markdown** with a [normal](https://x.test) link."
        #expect(WikiLinkMarkdown.linkified(body) == body)
    }

    @Test func displayBracketsAreEscapedSoTheyDontBreakMarkdown() {
        // The grammar forbids `]` in an alias, but a `[` is allowed and would
        // otherwise be read as the start of a nested Markdown link; escape it.
        let out = WikiLinkMarkdown.linkified("[[Home|a [b c]]")
        #expect(out == "[a \\[b c](wiki://page?title=Home)")
    }

    @Test func idempotenceOnAlreadyLinkifiedOutput() {
        // The output has no `[[…]]`, so a second pass changes nothing.
        let once = WikiLinkMarkdown.linkified("[[Home]] and [[Away]]")
        #expect(WikiLinkMarkdown.linkified(once) == once)
    }

    // MARK: - URL round-trip helpers

    @Test func targetExtractsTitleFromOurURLs() {
        let resolved = URL(string: "wiki://page?title=Calvin%20Cycle")!
        let missing = URL(string: "wiki://missing?title=Ghost")!
        #expect(WikiLinkMarkdown.target(from: resolved) == "Calvin Cycle")
        #expect(WikiLinkMarkdown.target(from: missing) == "Ghost")
        #expect(WikiLinkMarkdown.isResolvedURL(resolved))
        #expect(!WikiLinkMarkdown.isResolvedURL(missing))
    }

    @Test func targetRejectsForeignURLs() {
        #expect(WikiLinkMarkdown.target(from: URL(string: "https://example.com?title=X")!) == nil)
        #expect(WikiLinkMarkdown.target(from: URL(string: "wiki://page")!) == nil)
    }

    // Pull the URL substring out of a single `[text](url)` for assertions.
    private func extractURL(_ markdownLink: String) -> String {
        guard let open = markdownLink.lastIndex(of: "("),
              let close = markdownLink.lastIndex(of: ")") else { return "" }
        return String(markdownLink[markdownLink.index(after: open)..<close])
    }
}
