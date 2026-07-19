import Foundation
import Testing
@testable import WikiFSCore

/// Round-trip tests for the drag-wikilinks feature (issue #616): the parser
/// must accept what `DroppedLinkFormatter` produces, AND the Phase 5
/// `WikiLinkRewriter.canonicalize` must be a no-op on the formatter's output
/// (proving the drop-inserted link is already canonical — save won't rewrite
/// it). Together with `DroppedLinkFormatterTests`, this pins AC.7 (round-trip
/// canonical + rewriter no-op) and AC.6 (formatter correctness).
///
/// Pure / MainActor-free / no DB / no UI — fast tier.
struct DroppedLinkRoundTripTests {

    // Valid 26-char Crockford base32 ids (the confusable I/L/O/U are absent),
    // matching the canonical-ULID shape used in `WikiLinkCanonicalizerTests`.
    private let pageID = "01HXXXXXXXXXXXXXXXXXXXXXXX"
    private let sourceID = "01HYYYYYYYYYYYYYYYYYYYYYYY"
    private let chatID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"

    // MARK: - Single-link round trip (parser ↔ formatter)

    /// The parser yields exactly one `ParsedLink` with the right linkType,
    /// the ULID as `target`, the alias as `linkText`, and `isCanonicalULID`
    /// true on the target — for every kind the formatter emits.
    @Test func parserAcceptsFormatterOutput_page() throws {
        let emitted = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: "Home")
        let links = WikiLinkParser.parse(emitted)
        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.linkType == .page)
        #expect(link.target == pageID)
        #expect(link.linkText == "Home")
        #expect(WikiLinkParser.isCanonicalULID(link.target))
    }

    @Test func parserAcceptsFormatterOutput_source() throws {
        let emitted = DroppedLinkFormatter.link(
            for: .source, id: sourceID, displayName: "Paper")
        let links = WikiLinkParser.parse(emitted)
        let link = try #require(links.first)
        #expect(link.linkType == .source)
        #expect(link.target == sourceID)
        #expect(link.linkText == "Paper")
        #expect(WikiLinkParser.isCanonicalULID(link.target))
    }

    @Test func parserAcceptsFormatterOutput_chat() throws {
        let emitted = DroppedLinkFormatter.link(
            for: .chat, id: chatID, displayName: "Conversation")
        let links = WikiLinkParser.parse(emitted)
        let link = try #require(links.first)
        #expect(link.linkType == .chat)
        #expect(link.target == chatID)
        #expect(link.linkText == "Conversation")
        #expect(WikiLinkParser.isCanonicalULID(link.target))
    }

    /// When `displayName` resolved stale (nil), the formatter falls back to
    /// the raw ULID as the alias. Make sure that round-trips to a link where
    /// `target` and `linkText` are both the ULID — the link still resolves by
    /// id (the alias is cosmetic).
    @Test func parserAcceptsFormatterOutput_nilAliasFallsBackToULID() throws {
        let emitted = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: nil)
        let link = try #require(WikiLinkParser.parse(emitted).first)
        #expect(link.linkType == .page)
        #expect(link.target == pageID)
        // Alias is the ULID verbatim, not the empty string.
        #expect(link.linkText == pageID)
        #expect(WikiLinkParser.isCanonicalULID(link.target))
    }

    // MARK: - Rewriter idempotency (the load-bearing save-time guarantee)

    /// `WikiLinkRewriter.canonicalize` MUST return `nil` (no-op) on a
    /// formatter-emitted single link embedded in a body — proving the drop-
    /// inserted link is already canonical and the explicit Save path won't
    /// rewrite it. This is the single load-bearing guarantee that makes
    /// inserting the canonical form at drop time strictly better than inserting
    /// the human form (which the rewriter would rewrite on save).
    @Test func rewriterIsNoOpOnFormatterEmittedPageLink() throws {
        let link = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: "Home")
        let body = "See \(link) for details."
        // No-resolvers is the strictest test: even with no name→id resolution
        // available, an already-canonical target skips the rewrite path
        // (`isCanonicalULID(target) → continue`), so the body is untouched.
        let out = try WikiLinkRewriter.canonicalize(
            in: body,
            resolvePage: { _ in nil },
            resolveSource: { _ in nil },
            resolveChat: { _ in nil })
        #expect(out == nil)
    }

    @Test func rewriterIsNoOpOnFormatterEmittedSourceLink() throws {
        let body = DroppedLinkFormatter.link(
            for: .source, id: sourceID, displayName: "Paper")
        let out = try WikiLinkRewriter.canonicalize(
            in: body,
            resolvePage: { _ in nil },
            resolveSource: { _ in nil },
            resolveChat: { _ in nil })
        #expect(out == nil)
    }

    @Test func rewriterIsNoOpOnFormatterEmittedChatLink() throws {
        let body = DroppedLinkFormatter.link(
            for: .chat, id: chatID, displayName: "Conversation")
        let out = try WikiLinkRewriter.canonicalize(
            in: body,
            resolvePage: { _ in nil },
            resolveSource: { _ in nil },
            resolveChat: { _ in nil })
        #expect(out == nil)
    }

    /// Multi-target rewriters (with name→id maps that would normally rewrite
    /// `[[Home]]` → `[[page:ULID|Home]]`) are STILL no-ops on already-canonical
    /// drop-inserted text. Confirms the rewriter's idempotency fast-path kicks
    /// in even when name resolution would otherwise succeed.
    @Test func rewriterIsNoOpEvenWhenResolversCanResolveByName() throws {
        let resolvers: (page: (String) throws -> PageID?,
                        source: (String) throws -> PageID?,
                        chat: (String) throws -> PageID?) = (
            page: { _ in PageID(rawValue: "01HWIKIPEDIAFORCESTUBEXXXXXXXXX") },
            source: { _ in PageID(rawValue: "01JWIKIPEDIAFORCESTUBEXXXXXXXXX") },
            chat: { _ in PageID(rawValue: "01KXWIKIPEDIAFORCESTUBEXXXXXXXX") }
        )
        let pageLink = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: "Home")
        let sourceLink = DroppedLinkFormatter.link(
            for: .source, id: sourceID, displayName: "Paper")
        let body = "\(pageLink) and \(sourceLink)"
        let out = try WikiLinkRewriter.canonicalize(
            in: body,
            resolvePage: resolvers.page,
            resolveSource: resolvers.source,
            resolveChat: resolvers.chat)
        #expect(out == nil)
    }

    // MARK: - Multi-line list round trip (the v1 multi-payload output)

    /// A flat depth-0 markdown list of canonical links, embedded in a body,
    /// round-trips through the parser: each `- [[kind:ULID|alias]]` line
    /// yields exactly one `ParsedLink`, none are silently dropped, and the
    /// surrounding bullet/indent is preserved verbatim in the body (the parser
    /// only extracts `[[…]]` spans, not the surrounding list syntax).
    @Test func parserExtractsEveryLineOfFlatListWithoutLoss() {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: "Home"),
            DroppedLinkFormatter.Item(depth: 0, linkType: .source,
                                     id: sourceID, displayName: "Paper"),
            DroppedLinkFormatter.Item(depth: 0, linkType: .chat,
                                     id: chatID, displayName: "Convo"),
        ]
        let listBlock = DroppedLinkFormatter.markdownList(for: items)
        // Wrap in a realistic body the way the editor would after a drop:
        let body = "References:\n\(listBlock)\nEnd."
        let parsed = WikiLinkParser.parse(body)

        #expect(parsed.count == 3)
        #expect(parsed[0].linkType == .page)
        #expect(parsed[0].target == pageID)
        #expect(parsed[0].linkText == "Home")
        #expect(parsed[1].linkType == .source)
        #expect(parsed[1].target == sourceID)
        #expect(parsed[1].linkText == "Paper")
        #expect(parsed[2].linkType == .chat)
        #expect(parsed[2].target == chatID)
        #expect(parsed[2].linkText == "Convo")

        // The list block must be byte-for-byte intact in the body (the parser
        // doesn't have to touch it — drop-inserted text is preserved).
        #expect(body.contains(listBlock))
    }

    /// The rewriter is a no-op on the multi-line list block too — so saving a
    /// page with a multi-payload drop in it doesn't churn the body. (Same
    /// guarantee as the single-link case, applied to the v1 multi-payload
    /// shape.)
    @Test func rewriterIsNoOpOnFlatMarkdownList() throws {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: "Home"),
            DroppedLinkFormatter.Item(depth: 0, linkType: .source,
                                     id: sourceID, displayName: "Paper"),
        ]
        let body = "References:\n\(DroppedLinkFormatter.markdownList(for: items))"
        let out = try WikiLinkRewriter.canonicalize(
            in: body,
            resolvePage: { _ in nil },
            resolveSource: { _ in nil },
            resolveChat: { _ in nil })
        #expect(out == nil)
    }

    /// Nested-depth list (the forward-compatible shape v1 doesn't emit but the
    /// formatter signature supports) also parses line-for-line — pinning the
    /// contract so the follow-up PR that ships Option A can rely on the same
    /// round-trip.
    @Test func parserExtractsEveryLineOfNestedListWithoutLoss() {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: "Home"),
            DroppedLinkFormatter.Item(depth: 1, linkType: .source,
                                     id: sourceID, displayName: "Paper"),
            DroppedLinkFormatter.Item(depth: 2, linkType: .chat,
                                     id: chatID, displayName: "Convo"),
        ]
        let body = DroppedLinkFormatter.markdownList(for: items)
        let parsed = WikiLinkParser.parse(body)
        #expect(parsed.count == 3)
        #expect(parsed[0].linkType == .page)
        #expect(parsed[1].linkType == .source)
        #expect(parsed[2].linkType == .chat)
        #expect(Set(parsed.map(\.target)) == Set([pageID, sourceID, chatID]))
        // The body's list structure (indentation, `- ` prefixes) is untouched.
        let expected = """
        - [[page:\(pageID)|Home]]
          - [[source:\(sourceID)|Paper]]
            - [[chat:\(chatID)|Convo]]
        """
        #expect(body == expected)
    }
}
