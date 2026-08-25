import Testing
@testable import WikiFSCore

struct WikiMarkdownSyntaxTests {
    @Test func preservesEveryOccurrenceAndCanonicalUTF8Ranges() throws {
        let markdown = "π [[Page|first]] and [[Page|second]]"
        let nodes = WikiLinkParser.syntaxNodes(in: markdown)

        #expect(nodes.count == 2)
        #expect(nodes.map(\.authoredLiteral) == ["[[Page|first]]", "[[Page|second]]"])
        #expect(nodes[0].sourceRange.lowerBound == "π ".utf8.count)
        #expect(nodes[0].sourceRange.upperBound == "π [[Page|first]]".utf8.count)
    }

    @Test func distinguishesLinksAndEmbedsWithTaggedTargets() throws {
        let nodes = WikiLinkParser.syntaxNodes(
            in: "[[page:Home#Top|start]] ![[source:diagram.mmd@v3|map]] ![[Notes#Details]] [[chat:Thread]]")

        #expect(nodes.count == 4)
        guard case .link(let page) = nodes[0],
              case .embed(let source) = nodes[1],
              case .embed(let transclusion) = nodes[2],
              case .link(let chat) = nodes[3] else {
            Issue.record("Unexpected typed wiki syntax cases")
            return
        }
        #expect(page.target.namespace == .page)
        #expect(page.target.fragment == "Top")
        #expect(page.alias == "start")
        #expect(source.target.namespace == .source)
        #expect(source.target.sourceVersionPin == 3)
        #expect(source.displayText == "map")
        #expect(transclusion.target.namespace == .page)
        #expect(transclusion.target.fragment == "Details")
        #expect(chat.target.namespace == .chat)
    }

    @Test func skipsCodeSpansAndFencesButKeepsAdjacentSyntax() {
        let markdown = """
        before [[Live]] and `[[Code]]` after

        ```text
        ![[source:inside.png]]
        ```

        ![[source:outside.png]]
        """
        let nodes = WikiLinkParser.syntaxNodes(in: markdown)
        #expect(nodes.map(\.authoredLiteral) == ["[[Live]]", "![[source:outside.png]]"])
    }

    @Test func handlesCRLFUnicodeAndAdjacentOverlays() {
        let markdown = "α\r\n> [[One]][[source:Two]]"
        let nodes = WikiLinkParser.syntaxNodes(in: markdown)
        #expect(nodes.count == 2)
        #expect(nodes[0].sourceRange.upperBound == nodes[1].sourceRange.lowerBound)
        #expect(nodes.map(\.authoredLiteral) == ["[[One]]", "[[source:Two]]"])
    }

    @Test func typedNodesContainAuthoredSyntaxNotGeneratedMarkup() {
        let nodes = WikiLinkParser.syntaxNodes(in: "![[source:diagram.mmd]] ![[Page]]")
        #expect(nodes.count == 2)
        for node in nodes {
            #expect(!node.authoredLiteral.contains("iframe"))
            #expect(!node.authoredLiteral.contains("details"))
            #expect(!node.authoredLiteral.contains("sdw-renderer-card"))
            #expect(!node.authoredLiteral.contains("```mermaid"))
        }
    }
}
