import Foundation
import Testing
@testable import WikiFSCore

/// Pure-function unit tests for `DroppedLinkFormatter` (issue #616).
///
/// The formatter is the load-bearing correctness piece of the drag-sidebar-
/// into-editor feature: it produces the canonical `[[kind:<ULID>|<alias>]]`
/// form that the Phase 5 `WikiLinkRewriter.canonicalize` idempotency fast-path
/// leaves byte-identical on save. These tests pin the four acceptance criteria
/// that depend solely on the formatter's output (the round-trip tests in
/// `DroppedLinkRoundTripTests` cover the parser-side acceptance).
///
/// All tests are MainActor-free (the formatter is plain/Sendable; no AppKit, no
/// store) — fast tier only, no real DB, no UI.
struct DroppedLinkFormatterTests {

    // Valid 26-char Crockford base32 ids (the confusable I/L/O/U are absent),
    // matching the canonical-ULID shape used in `WikiLinkCanonicalizerTests`.
    private let pageID = "01HXXXXXXXXXXXXXXXXXXXXXXX"
    private let sourceID = "01HYYYYYYYYYYYYYYYYYYYYYYY"
    private let chatID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"

    // MARK: - link(for:id:displayName:)

    @Test func link_page_producesCanonicalPageLink() {
        let result = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: "Home")
        #expect(result == "[[page:\(pageID)|Home]]")
    }

    @Test func link_source_producesCanonicalSourceLink() {
        let result = DroppedLinkFormatter.link(
            for: .source, id: sourceID, displayName: "Paper")
        #expect(result == "[[source:\(sourceID)|Paper]]")
    }

    @Test func link_chat_producesCanonicalChatLink() {
        let result = DroppedLinkFormatter.link(
            for: .chat, id: chatID, displayName: "Conversation 1")
        #expect(result == "[[chat:\(chatID)|Conversation 1]]")
    }

    /// The alias is cosmetic but MUST survive: the formatter does not strip or
    /// normalize it (Phase 5 display-at-render resolves the ULID regardless of
    /// alias text, so a pre-canonicalized alias is left alone).
    @Test func link_preservesAliasWithSpacesAndPipes() {
        // An alias containing a space is valid as an alias (the alias is
        // rendered as the link text, not parsed as a target). A literal `|` in
        // the alias would break parsing — so use a space + hyphen case here;
        // the parser-tests file covers what chars round-trip.
        let result = DroppedLinkFormatter.link(
            for: .source, id: sourceID, displayName: "My Paper - v2")
        #expect(result == "[[source:\(sourceID)|My Paper - v2]]")
    }

    /// nil displayName → alias falls back to the raw ULID. The link is still
    /// well-formed and resolves by id at render (the alias is cosmetic). This
    /// is the path taken when a stale/deleted target's display name can't be
    /// resolved by the store.
    @Test func link_nilDisplayNameFallsBackToRawULID() {
        let result = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: nil)
        #expect(result == "[[page:\(pageID)|\(pageID)]]")
    }

    /// Empty-string displayName → also falls back to the raw ULID. This is the
    /// defensive path: `store.resolveAttachmentName(for:)` returning `""` (a
    /// weird edge case — title cleared but page still exists) could otherwise
    /// produce `[[page:ULID|]]` which the parser would treat as an empty
    /// alias. Treat empty as nil so the alias always has content.
    @Test func link_emptyDisplayNameFallsBackToRawULID() {
        let result = DroppedLinkFormatter.link(
            for: .page, id: pageID, displayName: "")
        // Same expectation as the nil case — alias falls back to the raw ULID.
        #expect(result == "[[page:\(pageID)|\(pageID)]]")
    }

    // MARK: - linkPrefix(for:)

    /// The formatter's prefix must match `ParsedLink.LinkType.linkPrefix`
    /// verbatim (the single source of truth — no inline literals at any call
    /// site). This guards against drift if `ResourceKind.linkPrefix` changes.
    @Test func linkPrefix_matchesParsedLinkLinkTypeLinkPrefix() {
        #expect(DroppedLinkFormatter.linkPrefix(for: .page) ==
                ParsedLink.LinkType.page.linkPrefix)
        #expect(DroppedLinkFormatter.linkPrefix(for: .source) ==
                ParsedLink.LinkType.source.linkPrefix)
        #expect(DroppedLinkFormatter.linkPrefix(for: .chat) ==
                ParsedLink.LinkType.chat.linkPrefix)
    }

    @Test func linkPrefix_isKindColonShape() {
        #expect(DroppedLinkFormatter.linkPrefix(for: .page) == "page:")
        #expect(DroppedLinkFormatter.linkPrefix(for: .source) == "source:")
        #expect(DroppedLinkFormatter.linkPrefix(for: .chat) == "chat:")
    }

    // MARK: - markdownList(for:)

    /// One depth-0 item → a single list line (no indent, `- ` prefix). Mirrors
    /// a drop of a single-leaf bookmark folder (the leafPayloads list has one
    /// target).
    @Test func markdownList_singleItemIsOneFlatLine() {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: "Home"),
        ]
        #expect(DroppedLinkFormatter.markdownList(for: items) ==
                "- [[page:\(pageID)|Home]]")
    }

    /// Two depth-0 items → two flat lines joined with `\n` (no indentation).
    /// This is the v1 multi-payload shape (a multi-row sidebar selection OR a
    /// bookmark folder with multiple leaves).
    @Test func markdownList_multipleItemsAreFlatDepth0() {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: "Home"),
            DroppedLinkFormatter.Item(depth: 0, linkType: .source,
                                     id: sourceID, displayName: "Paper"),
        ]
        #expect(DroppedLinkFormatter.markdownList(for: items) ==
                "- [[page:\(pageID)|Home]]\n- [[source:\(sourceID)|Paper]]")
    }

    /// Nested indentation is built into the formatter signature (forward-compat
    /// with `plans/drag-wikilinks.md` Step 3 Option A; v1 always passes depth
    /// 0). Pin the exact output: 2 spaces per depth level on the indent,
    /// `- ` prefix on every line, joined by `\n`.
    @Test func markdownList_indentsTwoSpacesPerDepthLevel() {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: "Home"),
            DroppedLinkFormatter.Item(depth: 1, linkType: .source,
                                     id: sourceID, displayName: "Paper"),
            DroppedLinkFormatter.Item(depth: 2, linkType: .chat,
                                     id: chatID, displayName: "Convo"),
        ]
        let expected = """
        - [[page:\(pageID)|Home]]
          - [[source:\(sourceID)|Paper]]
            - [[chat:\(chatID)|Convo]]
        """
        #expect(DroppedLinkFormatter.markdownList(for: items) == expected)
    }

    /// A nil displayName in any list item falls back to the raw ULID alias
    /// (multi-payload analog of `link_nilDisplayNameFallsBackToRawULID`).
    /// The list never silently drops a target — a stale leaf still becomes a
    /// link that resolves by id (and renders dimmed as a missing target).
    @Test func markdownList_nilDisplayNameFallsBackToRawULID() {
        let items = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                     id: pageID, displayName: nil),
        ]
        #expect(DroppedLinkFormatter.markdownList(for: items) ==
                "- [[page:\(pageID)|\(pageID)]]")
    }

    /// An empty item list produces an empty string — no crash, no stray `\n` or
    /// bullet, so a (defensive) builder that ends up with zero items inserts
    /// nothing (the editor's `performDragOperation` separately short-circuits
    /// an empty result, but the formatter itself must be total).
    @Test func markdownList_emptyIsEmptyString() {
        #expect(DroppedLinkFormatter.markdownList(for: []) == "")
    }

    /// A negative depth is clamped to 0 (defensive — `String(repeating:count:)`
    /// would crash on negative count). v1 never passes a negative depth, but
    /// the formatter must not crash if a future caller does.
    @Test func markdownList_negativeDepthClampsToZero() {
        let items = [
            DroppedLinkFormatter.Item(depth: -3, linkType: .page,
                                     id: pageID, displayName: "Home"),
        ]
        #expect(DroppedLinkFormatter.markdownList(for: items) ==
                "- [[page:\(pageID)|Home]]")
    }

    // MARK: - Convenience tuple overload

    /// The tuple-overload (`markdownList(forTuples:)`) must produce the same
    /// output as the `Item`-struct overload — it's just a call-site ergonomics
    /// shim. Pins the parity so a future refactor of one can't drift the other.
    @Test func markdownList_tupleOverloadMatchesStructOverload() {
        let tuples: [(depth: Int, linkType: ParsedLink.LinkType,
                      id: String, displayName: String?)] = [
            (depth: 0, linkType: .page,   id: pageID,   displayName: "Home"),
            (depth: 1, linkType: .source, id: sourceID, displayName: nil),
        ]
        let structs = [
            DroppedLinkFormatter.Item(depth: 0, linkType: .page,
                                      id: pageID, displayName: "Home"),
            DroppedLinkFormatter.Item(depth: 1, linkType: .source,
                                      id: sourceID, displayName: nil),
        ]
        #expect(DroppedLinkFormatter.markdownList(forTuples: tuples) ==
                DroppedLinkFormatter.markdownList(for: structs))
    }

    // MARK: - ULID shape (mirrors WikiLinkParser.isCanonicalULID)

    /// The id substring of every emitted link MUST be a 26-char Crockford-
    /// base32 string, mirroring `WikiLinkParser.isCanonicalULID`. If the
    /// formatter emits anything else, the Phase 5 rewriter's idempotency
    /// fast-path (`isCanonicalULID(target) → skip`) won't recognize it as
    /// already-canonical and would rewrite it on save — defeating the whole
    /// point of inserting the canonical form at drop time.
    @Test func link_idSubstringIs26CharCrockfordBase32() {
        for (type, id) in [(ParsedLink.LinkType.page, pageID),
                           (ParsedLink.LinkType.source, sourceID),
                           (ParsedLink.LinkType.chat, chatID)] {
            let emitted = DroppedLinkFormatter.link(
                for: type, id: id, displayName: "alias")
            #expect(emitted.contains(id))
            #expect(WikiLinkParser.isCanonicalULID(id))
        }
    }
}
