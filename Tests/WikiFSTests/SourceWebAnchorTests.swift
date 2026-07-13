import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for the source web reader's anchor resolution — the Swift-side logic
/// that decides whether a consumed `[[source:Name#…]]` fragment scrolls to a
/// heading or highlights a quote. (The JS application — scrollIntoView /
/// window.find + `<mark>` — runs inside WKWebView and is covered manually.)
struct SourceWebAnchorTests {

    @Test func headingFragmentResolvesToHeading() {
        let blocks = AnchorBlock.parse("# Methodology\n\nbody text")
        let target = WikiReaderView.resolveScrollTarget("Methodology", blocks: blocks)
        #expect(target == .heading(slug: "methodology"))
    }

    @Test func quotedFragmentResolvesToQuote() {
        // A `"quote"` matches a paragraph by substring (resolveAnchor), so it's
        // not a heading → quote highlight.
        let blocks = AnchorBlock.parse("# Intro\n\nThe results show a 30% improvement.")
        let target = WikiReaderView.resolveScrollTarget("\"30% improvement\"", blocks: blocks)
        if case .quote(let q) = target {
            #expect(q == "30% improvement")
        } else {
            Issue.record("expected .quote, got \(String(describing: target))")
        }
    }

    @Test func quoteNormalizesInternalWhitespace() {
        let blocks = AnchorBlock.parse("# Intro\n\nText.")
        let target = WikiReaderView.resolveScrollTarget("\"a   b\"", blocks: blocks)
        if case .quote(let q) = target {
            #expect(q == "a b")
        } else {
            Issue.record("expected .quote")
        }
    }

    @Test func unknownFragmentFallsBackToQuote() {
        let blocks = AnchorBlock.parse("# Intro\n\nText.")
        let target = WikiReaderView.resolveScrollTarget("not a heading anywhere", blocks: blocks)
        if case .quote = target {
            // ok
        } else {
            Issue.record("expected quote fallback for an unresolved fragment")
        }
    }

    @Test func emptyQuoteReturnsNil() {
        let blocks = AnchorBlock.parse("# Intro\n\nText.")
        #expect(WikiReaderView.resolveScrollTarget("\"\"", blocks: blocks) == nil)
    }
}
