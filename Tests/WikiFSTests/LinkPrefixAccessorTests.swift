import Testing
@testable import WikiFSCore

/// Tests for the consolidated link-kind prefix and host accessor constants (#489).
/// After this refactoring, `rg '"page:"|"source:"|"chat:"' Sources/ -t swift`
/// returns zero hits outside the accessor definitions — these tests ensure the
/// prefixes still flow correctly through the single source of truth.
struct LinkPrefixAccessorTests {

    // MARK: - ResourceKind.linkPrefix

    @Test func resourceKindLinkPrefixReturnsExpectedValues() {
        #expect(ResourceKind.page.linkPrefix == "page:")
        #expect(ResourceKind.source.linkPrefix == "source:")
        #expect(ResourceKind.chat.linkPrefix == "chat:")
        #expect(ResourceKind.bookmark.linkPrefix == "bookmark:")
    }

    @Test func resourceKindLinkPrefixReturnsNilForNonLinkableKinds() {
        #expect(ResourceKind.systemPrompt.linkPrefix == nil)
        #expect(ResourceKind.wikiIndex.linkPrefix == nil)
        #expect(ResourceKind.log.linkPrefix == nil)
    }

    @Test func resourceKindLinkPrefixMatchesRawValueForLinkable() {
        for kind in ResourceKind.allCases where kind.linkPrefix != nil {
            #expect(kind.linkPrefix == "\(kind.rawValue):")
        }
    }

    // MARK: - ParsedLink.LinkType bridge

    @Test func linkTypeResourceKindBridgesCorrectly() {
        #expect(ParsedLink.LinkType.page.resourceKind == .page)
        #expect(ParsedLink.LinkType.source.resourceKind == .source)
        #expect(ParsedLink.LinkType.chat.resourceKind == .chat)
    }

    @Test func linkTypeLinkPrefixIsNonOptionalAndMatchesResourceKind() {
        for kind in ParsedLink.LinkType.allCases {
            #expect(kind.linkPrefix == kind.resourceKind.linkPrefix)
            #expect(!kind.linkPrefix.isEmpty)
        }
    }

    @Test func linkTypeLinkPrefixReturnsExpectedValues() {
        #expect(ParsedLink.LinkType.page.linkPrefix == "page:")
        #expect(ParsedLink.LinkType.source.linkPrefix == "source:")
        #expect(ParsedLink.LinkType.chat.linkPrefix == "chat:")
    }

    // MARK: - Host constants

    @Test func wikiLinkMarkdownHostConstants() {
        #expect(WikiLinkMarkdown.resolvedHost == "page")
        #expect(WikiLinkMarkdown.sourceHost == "source")
        #expect(WikiLinkMarkdown.chatHost == "chat")
        #expect(WikiLinkMarkdown.anchorHost == "anchor")
        #expect(WikiLinkMarkdown.unresolvedHost == "missing")
    }

    // MARK: - End-to-end: typed prefix flows through the parser

    @Test func classifyUsesTypedPrefix() {
        let (pageKind, pageTarget) = WikiLinkParser.classify("page:My Page")
        #expect(pageKind == .page)
        #expect(pageTarget == "My Page")

        let (sourceKind, sourceTarget) = WikiLinkParser.classify("source:A.pdf")
        #expect(sourceKind == .source)
        #expect(sourceTarget == "A.pdf")

        let (chatKind, chatTarget) = WikiLinkParser.classify("chat:Conversation")
        #expect(chatKind == .chat)
        #expect(chatTarget == "Conversation")
    }

    @Test func isEmptyPrefixUsesTypedPrefix() {
        #expect(WikiLinkParser.isEmptyPrefix("source:"))
        #expect(WikiLinkParser.isEmptyPrefix("page:   "))
        #expect(WikiLinkParser.isEmptyPrefix("chat:"))
        #expect(!WikiLinkParser.isEmptyPrefix("page:Foo"))
        #expect(!WikiLinkParser.isEmptyPrefix("OrdinaryTitle"))
    }
}
