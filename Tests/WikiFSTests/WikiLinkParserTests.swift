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
}
