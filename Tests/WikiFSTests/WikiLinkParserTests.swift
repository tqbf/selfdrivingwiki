import Testing
@testable import WikiFSCore

/// Unit tests for the pure `[[wiki-link]]` parser (INITIAL §4 v1).
struct WikiLinkParserTests {

    @Test func parsesSimpleLink() {
        let links = WikiLinkParser.parse("See [[Home]] for details.")
        #expect(links == [.init(target: "Home", linkText: "Home")])
    }

    @Test func parsesAliasedLink() {
        let links = WikiLinkParser.parse("See [[Home|the front page]].")
        #expect(links == [.init(target: "Home", linkText: "the front page")])
    }

    @Test func parsesMultipleLinks() {
        let links = WikiLinkParser.parse("[[Alpha]] then [[Beta|B]] then [[Gamma]]")
        #expect(links == [
            .init(target: "Alpha", linkText: "Alpha"),
            .init(target: "Beta", linkText: "B"),
            .init(target: "Gamma", linkText: "Gamma"),
        ])
    }

    @Test func dedupesByTargetFirstAliasWins() {
        let links = WikiLinkParser.parse("[[Home|first]] and again [[Home|second]] and [[Home]]")
        #expect(links == [.init(target: "Home", linkText: "first")])
    }

    @Test func skipsEmptyTargets() {
        #expect(WikiLinkParser.parse("[[]] and [[   ]] are empty").isEmpty)
    }

    @Test func collapsesAndTrimsWhitespaceInTarget() {
        let links = WikiLinkParser.parse("[[  Home   Page  ]]")
        #expect(links == [.init(target: "Home Page", linkText: "Home Page")])
    }

    @Test func emptyAliasFallsBackToTarget() {
        let links = WikiLinkParser.parse("[[Home|   ]]")
        #expect(links == [.init(target: "Home", linkText: "Home")])
    }

    @Test func ignoresUnmatchedBrackets() {
        // A single `[` / `]`, or an unterminated `[[`, is not a link.
        #expect(WikiLinkParser.parse("a [single] and an open [[unterminated link").isEmpty)
    }

    @Test func returnsEmptyForNoLinks() {
        #expect(WikiLinkParser.parse("just some plain markdown text").isEmpty)
    }

    // MARK: - source: prefix (Phase B)

    @Test func parsesSourcePrefixLink() {
        let links = WikiLinkParser.parse("See [[source:My Notes]].")
        #expect(links.count == 1)
        #expect(links[0].linkType == .source)
        #expect(links[0].target == "My Notes")
        #expect(links[0].linkText == "My Notes")
    }

    @Test func sourceLinkWithAliasPreservesAlias() {
        let links = WikiLinkParser.parse("[[source:My Notes|my notes]]")
        #expect(links[0].linkType == .source)
        #expect(links[0].target == "My Notes")
        #expect(links[0].linkText == "my notes")
    }

    @Test func sourcePrefixNormalizesRemainder() {
        let links = WikiLinkParser.parse("[[source:  X  ]]")
        #expect(links[0].target == "X") // no leading/trailing space
    }

    @Test func emptySourceTargetIsSkipped() {
        let links = WikiLinkParser.parse("[[source:]] and [[source:   ]]")
        #expect(links.isEmpty)
    }

    @Test func pagePrefixEscapesSourcePrefixTitle() {
        // A page literally titled "source:foo" is reachable via [[page:source:foo]].
        let links = WikiLinkParser.parse("[[page:source:foo]]")
        #expect(links[0].linkType == .page)
        #expect(links[0].target == "source:foo")
    }

    @Test func sourceAndPageLinksDedupSeparately() {
        let links = WikiLinkParser.parse("[[source:X|a]] [[source:X|b]] [[X]] [[source:X]]")
        #expect(links.count == 2) // one page link "X" + one source link "X"
        let sourceLink = links.first { $0.linkType == .source }
        #expect(sourceLink?.linkText == "a") // first alias wins
    }

    // MARK: - classify

    @Test func classifyDefaultsToPage() {
        let (kind, target) = WikiLinkParser.classify("Plain Title")
        #expect(kind == .page)
        #expect(target == "Plain Title")
    }

    @Test func classifySourcePrefix() {
        let (kind, target) = WikiLinkParser.classify("source:My Notes")
        #expect(kind == .source)
        #expect(target == "My Notes") // prefix stripped, remainder normalized
    }

    @Test func classifyPagePrefixTakesPrecedence() {
        let (kind, target) = WikiLinkParser.classify("page:source:foo")
        #expect(kind == .page)
        #expect(target == "source:foo")
    }

    @Test func classifyEmptySourceTargetFallsBackToPage() {
        // peel returns nil (rest is empty), so classify falls through → .page with
        // the original string. The parser's skip logic handles the empty-prefix case.
        let (kind, target) = WikiLinkParser.classify("source:")
        #expect(kind == .page)
        #expect(target == "source:")
    }

    // MARK: - splitFragment

    @Test func splitFragmentNoHashReturnsNilFragment() {
        let (base, fragment) = WikiLinkParser.splitFragment("Plain Title")
        #expect(base == "Plain Title")
        #expect(fragment == nil)
    }

    @Test func splitFragmentSingleHashSplitsCorrectly() {
        let (base, fragment) = WikiLinkParser.splitFragment("Page#Section")
        #expect(base == "Page")
        #expect(fragment == "Section")
    }

    @Test func splitFragmentEmptyBaseIsSamePage() {
        let (base, fragment) = WikiLinkParser.splitFragment("#Section")
        #expect(base == "")
        #expect(fragment == "Section")
    }

    @Test func splitFragmentPreservesInnerHash() {
        // "C# is a language" stays intact — only the FIRST # splits.
        let (base, fragment) = WikiLinkParser.splitFragment("source:X#C# is a language")
        #expect(base == "source:X")
        #expect(fragment == "C# is a language")
    }

    @Test func splitFragmentEmptyFragmentAfterHashReturnsNil() {
        let (base, fragment) = WikiLinkParser.splitFragment("Page#")
        #expect(base == "Page")
        #expect(fragment == nil)
    }

    @Test func splitFragmentOnlyHashReturnsEmptyBaseAndNilFragment() {
        let (base, fragment) = WikiLinkParser.splitFragment("#")
        #expect(base == "")
        #expect(fragment == nil)
    }

    // MARK: - parse with #fragment

    @Test func parsesPageLinkWithHeadingFragment() {
        let links = WikiLinkParser.parse("[[Overview#Methodology]]")
        #expect(links.count == 1)
        #expect(links[0].linkType == .page)
        #expect(links[0].target == "Overview")
        #expect(links[0].fragment == "Methodology")
    }

    @Test func parsesSourceLinkWithQuoteFragment() {
        let links = WikiLinkParser.parse("[[source:Paper#the results show]]")
        #expect(links.count == 1)
        #expect(links[0].linkType == .source)
        #expect(links[0].target == "Paper")
        #expect(links[0].fragment == "the results show")
    }

    @Test func parsesSourceLinkWithQuotedFragmentPreservesQuotes() {
        // Quotes are stripped at resolution time, not parse time.
        let links = WikiLinkParser.parse("[[source:Smith#\"exact passage\"]]")
        #expect(links[0].fragment == "\"exact passage\"")
    }

    @Test func parsesLinkWithAliasAndFragment() {
        let links = WikiLinkParser.parse("[[Page#Section|my label]]")
        #expect(links.count == 1)
        #expect(links[0].target == "Page")
        #expect(links[0].fragment == "Section")
        #expect(links[0].linkText == "my label")
    }

    @Test func samePageAnchorIsSkippedInParse() {
        // [[#Section]] has empty base — not a page/source link, skip in graph.
        let links = WikiLinkParser.parse("[[#Section]]")
        #expect(links.isEmpty)
    }

    @Test func samePageQuotedAnchorIsSkippedInParse() {
        let links = WikiLinkParser.parse("[[#\"a quote\"]]")
        #expect(links.isEmpty)
    }

    @Test func distinctFragmentsDedupSeparately() {
        // [[Page#A]] and [[Page#B]] are DIFFERENT raw targets — they may be
        // two distinct `#`-containing titles — so both survive parse. When
        // they resolve to one page, the store's (from,to) primary key
        // collapses them (first link text wins, as before).
        let links = WikiLinkParser.parse("[[Page#A|first]] and [[Page#B|second]]")
        #expect(links.count == 2)
        #expect(links[0].fragment == "A")
        #expect(links[1].fragment == "B")
    }

    @Test func identicalRawTargetsStillDedup() {
        let links = WikiLinkParser.parse("[[Page#A|first]] and [[Page#A|second]]")
        #expect(links.count == 1)
        #expect(links[0].linkText == "first")
    }

    @Test func hashTitlesWithSharedMisSplitBaseBothSurvive() {
        // "C# Guide" and "C# Notes" both mis-split to base "C" — they must not
        // collapse into one parsed link (each may name a real `#`-title).
        let links = WikiLinkParser.parse("[[C# Guide]] and [[C# Notes]]")
        #expect(links.count == 2)
    }

    @Test func sourcePrefixFragmentPreservesInnerHash() {
        let links = WikiLinkParser.parse("[[source:Paper#C# is sharp]]")
        #expect(links.count == 1)
        #expect(links[0].linkType == .source)
        #expect(links[0].target == "Paper")
        #expect(links[0].fragment == "C# is sharp")
    }

    // MARK: - `#` inside the NAME (quote anchor is the delimiter)

    @Test func splitFragmentQuoteAnchorWinsOverHashInName() {
        // The NAME contains a bare `#` ("C#"); the quote anchor `#"…"` is the
        // real delimiter, so the name survives intact.
        let (base, fragment) = WikiLinkParser.splitFragment(
            "source:Agentic Static Analysis for C# Security Auditing (2026)#\"the results show\"")
        #expect(base == "source:Agentic Static Analysis for C# Security Auditing (2026)")
        #expect(fragment == "\"the results show\"")
    }

    @Test func splitFragmentBareHashWithoutAnchorStillSplitsAtFirstHash() {
        // With no `#"` there is nothing to disambiguate — the first `#` splits.
        // Resolution retries with the fragment re-attached (replaceLinks /
        // linkified), so a title containing `#` still resolves.
        let (base, fragment) = WikiLinkParser.splitFragment(
            "Agentic Static Analysis for C# Security Auditing")
        #expect(base == "Agentic Static Analysis for C")
        #expect(fragment == " Security Auditing")
    }

    @Test func parsesSourceCitationWithHashInName() {
        let links = WikiLinkParser.parse(
            "[[source:Agentic Static Analysis for C# Security Auditing (2026)#\"as we show\"]]")
        #expect(links.count == 1)
        #expect(links[0].linkType == .source)
        #expect(links[0].target == "Agentic Static Analysis for C# Security Auditing (2026)")
        #expect(links[0].fragment == "\"as we show\"")
    }

    @Test func quotedSamePageAnchorStillHasEmptyBase() {
        // `#"` at position 0 — quote-anchor preference must not break `[[#"…"]]`.
        let (base, fragment) = WikiLinkParser.splitFragment("#\"a quote\"")
        #expect(base == "")
        #expect(fragment == "\"a quote\"")
    }
}
