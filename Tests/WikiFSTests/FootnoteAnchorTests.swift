import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for footnote-reference → definition scroll in the WKWebView readers.
/// A `[^id]` reference is rewritten to a same-page fragment link
/// (`#wiki-fn-<id>`); the definition appendix gets a matching `id="wiki-fn-<id>"`
/// anchor; WKWebView scrolls to it natively on click. These assert the pure
/// invariant — the fragment href and the element id MUST agree — plus that the
/// anchors survive the HTML render. (The live native scroll is a manual gate.)
struct FootnoteAnchorTests {

    private static let footnoteMarkdown = """
    See this note[^n] and that note[^other].

    [^n]: First definition.
    [^other]: Second definition.
    """

    // MARK: - footnoteAnchorID

    @Test func anchorIDForSimpleID() {
        #expect(WikiFootnoteMarkdown.footnoteAnchorID(for: "n") == "wiki-fn-n")
    }

    @Test func anchorIDLeavesAllowedCharsUnencoded() {
        // Footnote ids are `[^\]\s]+` — no spaces — and common punctuation like
        // `-`/`.`/`_` needs no encoding, so a typical id maps 1:1.
        #expect(WikiFootnoteMarkdown.footnoteAnchorID(for: "note-1") == "wiki-fn-note-1")
    }

    @Test func anchorIDEncodesQueryMeaningfulChars() {
        #expect(WikiFootnoteMarkdown.footnoteAnchorID(for: "a&b") == "wiki-fn-a%26b")
    }

    // MARK: - Reference rewrite → fragment link

    @Test func referenceIsAFragmentLinkToTheAnchor() {
        let rendered = WikiFootnoteMarkdown.rendered(Self.footnoteMarkdown)
        // `[^n]` → [¹](#wiki-fn-n); the fragment is the anchor id (no scheme).
        #expect(rendered.bodyMarkdown.contains("[¹](#wiki-fn-n)"))
        #expect(rendered.bodyMarkdown.contains("[²](#wiki-fn-other)"))
    }

    // MARK: - Definition anchor + the load-bearing invariant

    @Test func preparedAppendixInjectsDefinitionAnchors() {
        let prepared = ReaderMarkdown.prepared(Self.footnoteMarkdown) { _, _ in true }
        // Each definition gets a wiki-fn-<id> anchor.
        #expect(prepared.contains("id=\"wiki-fn-n\""))
        #expect(prepared.contains("id=\"wiki-fn-other\""))
        // And the references are fragment links.
        #expect(prepared.contains("](#wiki-fn-n)"))
        #expect(prepared.contains("](#wiki-fn-other)"))
    }

    @Test func fragmentHrefMatchesDefinitionElementID() {
        // The whole point: the ref's href and the definition's id must be the
        // same string, or native WKWebView scroll won't find the target. Checked
        // on the fully rendered HTML (the format actually loaded into the view).
        let html = MarkdownHTMLRenderer.render(
            ReaderMarkdown.prepared(Self.footnoteMarkdown) { _, _ in true })
        for id in ["n", "other"] {
            let anchor = "id=\"wiki-fn-\(id)\""
            let href = "href=\"#wiki-fn-\(id)\""
            #expect(html.contains(anchor), "missing definition anchor \(anchor)")
            #expect(html.contains(href), "missing reference href \(href)")
        }
    }

    @Test func renderedHTMLContainsAnchorAndReferenceLink() {
        let html = MarkdownHTMLRenderer.render(
            ReaderMarkdown.prepared(Self.footnoteMarkdown) { _, _ in true })
        // The anchor element is emitted verbatim (raw inline HTML).
        #expect(html.contains("<a id=\"wiki-fn-n\"></a>"))
        // The reference is a real fragment <a href="#wiki-fn-n">.
        #expect(html.contains("href=\"#wiki-fn-n\""))
    }
}
