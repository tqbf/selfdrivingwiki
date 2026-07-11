import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the `[[wiki-link]]` → relative-Markdown-link rewriter used by
/// the `pages/by-title` FileProvider projection. No store, no view: the resolver
/// is injected as a closure, exactly as `Projection` supplies it.
struct RelativeLinkRewriterTests {

    private func resolve(_ title: String) -> String? {
        switch title {
        case "Home":     return "Home--01AAAAAAAA.md"
        case "Alpha":    return "Alpha--01BBBBBBBB.md"
        case "C# Guide": return "C# Guide--01CCCCCCCC.md"
        default:         return nil
        }
    }

    // MARK: - Basic rewrites

    @Test func simplePageLinkBecomesRelativeMarkdownLink() {
        let out = RelativeLinkRewriter.rewrite("See [[Home]] here.", resolver: resolve)
        #expect(out == "See [Home](Home--01AAAAAAAA.md) here.")
    }

    @Test func aliasedLinkUsesAliasTextAndTargetFilename() {
        let out = RelativeLinkRewriter.rewrite("Go to [[Home|start page]].", resolver: resolve)
        #expect(out == "Go to [start page](Home--01AAAAAAAA.md).")
    }

    @Test func multipleLinksAreEachRewritten() {
        let out = RelativeLinkRewriter.rewrite("[[Home]] and [[Alpha]].", resolver: resolve)
        #expect(out == "[Home](Home--01AAAAAAAA.md) and [Alpha](Alpha--01BBBBBBBB.md).")
    }

    // MARK: - Anchors

    @Test func anchorIsPreservedAfterFilename() {
        let out = RelativeLinkRewriter.rewrite("See [[Home#Introduction]].", resolver: resolve)
        #expect(out == "See [Home](Home--01AAAAAAAA.md#Introduction).")
    }

    @Test func aliasedAnchorLinkUsesAliasAndPreservesFragment() {
        let out = RelativeLinkRewriter.rewrite("[[Home#Intro|intro]]", resolver: resolve)
        #expect(out == "[intro](Home--01AAAAAAAA.md#Intro)")
    }

    // MARK: - Hash-in-title disambiguation

    @Test func hashInTitleIsDisambiguatedCorrectly() {
        // "C# Guide" is a real page; "C" is not. Should resolve to C# Guide.
        let out = RelativeLinkRewriter.rewrite("See [[C# Guide]].", resolver: resolve)
        #expect(out == "See [C# Guide](C%23%20Guide--01CCCCCCCC.md).")
    }

    // MARK: - Unresolvable links stay verbatim

    @Test func unknownPageLinkStaysVerbatim() {
        let out = RelativeLinkRewriter.rewrite("[[Deleted Page]]", resolver: resolve)
        #expect(out == "[[Deleted Page]]")
    }

    // MARK: - Non-page links stay verbatim

    @Test func sourceLinkStaysVerbatim() {
        let out = RelativeLinkRewriter.rewrite("[[source:report.pdf]]", resolver: resolve)
        #expect(out == "[[source:report.pdf]]")
    }

    @Test func chatLinkStaysVerbatim() {
        let out = RelativeLinkRewriter.rewrite("[[chat:My Chat]]", resolver: resolve)
        #expect(out == "[[chat:My Chat]]")
    }

    @Test func embedStaysVerbatim() {
        let out = RelativeLinkRewriter.rewrite("![[source:image.png]]", resolver: resolve)
        #expect(out == "![[source:image.png]]")
    }

    // MARK: - Code span protection

    @Test func linkInsideCodeSpanIsLeftVerbatim() {
        let out = RelativeLinkRewriter.rewrite("Use `[[Home]]` in code.", resolver: resolve)
        #expect(out == "Use `[[Home]]` in code.")
    }

    @Test func linkInsideFencedBlockIsLeftVerbatim() {
        let body = "```\n[[Home]]\n```"
        let out = RelativeLinkRewriter.rewrite(body, resolver: resolve)
        #expect(out == body)
    }

    // MARK: - Same-page anchors stay verbatim

    @Test func samePageAnchorStaysVerbatim() {
        let out = RelativeLinkRewriter.rewrite("Jump to [[#Introduction]].", resolver: resolve)
        #expect(out == "Jump to [[#Introduction]].")
    }

    // MARK: - Filename percent-encoding

    @Test func filenameWithSpecialCharsIsPercentEncoded() {
        // A filename with spaces must be percent-encoded so Markdown parsers
        // don't break the link at the first space.
        var called = false
        let out = RelativeLinkRewriter.rewrite("[[Home]]", resolver: { title in
            called = true
            return "My Home Page--01AA.md"   // has spaces
        })
        #expect(called)
        #expect(out == "[Home](My%20Home%20Page--01AA.md)")
    }

    // MARK: - Passthrough when no links

    @Test func bodyWithNoLinksIsReturnedUnchanged() {
        let body = "Just plain text, no wikilinks."
        let out = RelativeLinkRewriter.rewrite(body, resolver: resolve)
        #expect(out == body)
    }

    // MARK: - Frontmatter passthrough

    @Test func yamlFrontmatterIsNotModified() {
        let body = """
        ---
        title: "Home"
        date: 2026-07-11
        ---

        # Home

        See [[Alpha]].
        """
        let out = RelativeLinkRewriter.rewrite(body, resolver: resolve)
        #expect(out.hasPrefix("---\ntitle: \"Home\"\ndate: 2026-07-11\n---"))
        #expect(out.contains("[Alpha](Alpha--01BBBBBBBB.md)"))
    }
}
