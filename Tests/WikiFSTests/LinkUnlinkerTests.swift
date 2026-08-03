import Foundation
import Testing
@testable import WikiFSCore

/// Pure unit tests for `LinkUnlinker.unlink` (issue #219) — converting incoming
/// `[[wiki-link]]` spans whose target is being deleted to plain display text.
struct LinkUnlinkerTests {

    // Valid 26-char Crockford Base32 ids (the confusable I/L/O/U are absent).
    private let homeID = "01HXXXXXXXXXXXXXXXXXXXXXXX"
    private let paperID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"
    private let keepID = "01HYYYYYYYYYYYYYYYYYYYYYYY"

    /// Build resolver closures from name→id maps.
    private func resolvers(pages: [String: String] = [:], sources: [String: String] = [:])
        -> (resolvePage: (String) throws -> PageID?, resolveSource: (String) throws -> SourceID?) {
        let rp: (String) throws -> PageID? = { pages[$0].map { PageID(rawValue: $0) } }
        let rs: (String) throws -> SourceID? = { sources[$0].map { SourceID(rawValue: $0) } }
        return (rp, rs)
    }

    // MARK: - Page links

    @Test func unlinksCanonicalPageLinkByULID() throws {
        let (rp, rs) = resolvers()
        let out = try LinkUnlinker.unlink(
            in: "See [[page:\(homeID)|Home]] now.",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "See Home now.")
    }

    @Test func unlinksNameBasedPageLinkViaResolver() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try LinkUnlinker.unlink(
            in: "See [[Home]] now.",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "See Home now.")
    }

    @Test func preservesAuthoredAliasAsDisplayText() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try LinkUnlinker.unlink(
            in: "See [[Home|the home page]] now.",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "See the home page now.")
    }

    @Test func leavesUnrelatedPageLinkIntact() throws {
        let (rp, rs) = resolvers(pages: ["Keep": keepID, "Home": homeID])
        let out = try LinkUnlinker.unlink(
            in: "[[Keep]] and [[Home]]",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "[[Keep]] and Home")
    }

    // MARK: - Source links

    @Test func unlinksCanonicalSourceLinkByULID() throws {
        let (rp, rs) = resolvers()
        let out = try LinkUnlinker.unlink(
            in: "Cite [[source:\(paperID)|Paper]].",
            unlinkPageIDs: [],
            unlinkSourceIDs: [SourceID(rawValue: paperID)],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "Cite Paper.")
    }

    @Test func unlinksNameBasedSourceLinkViaResolver() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try LinkUnlinker.unlink(
            in: "Cite [[source:Paper]].",
            unlinkPageIDs: [],
            unlinkSourceIDs: [SourceID(rawValue: paperID)],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "Cite Paper.")
    }

    @Test func unlinksSourceCitationWithQuoteAnchor() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        // Quote anchor is dropped — it can't survive as plain text.
        let out = try LinkUnlinker.unlink(
            in: "[[source:Paper#\"a passage\"]]",
            unlinkPageIDs: [],
            unlinkSourceIDs: [SourceID(rawValue: paperID)],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "Paper")
    }

    // MARK: - Embeds

    @Test func unlinksEmbedConsumingBangPrefix() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try LinkUnlinker.unlink(
            in: "See ![[source:Paper|the figure]] here.",
            unlinkPageIDs: [],
            unlinkSourceIDs: [SourceID(rawValue: paperID)],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "See the figure here.")
    }

    @Test func unlinksEmbedWithoutAliasUsesBareName() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try LinkUnlinker.unlink(
            in: "See ![[source:Paper]] here.",
            unlinkPageIDs: [],
            unlinkSourceIDs: [SourceID(rawValue: paperID)],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "See Paper here.")
    }

    // MARK: - Safety / no-op

    @Test func returnsNilWhenNothingMatched() throws {
        let (rp, rs) = resolvers(pages: ["Keep": keepID])
        let out = try LinkUnlinker.unlink(
            in: "[[Keep]] only.",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == nil)
    }

    @Test func returnsNilWhenBothIdSetsEmpty() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try LinkUnlinker.unlink(
            in: "[[Home]]",
            unlinkPageIDs: [],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == nil)
    }

    @Test func leavesCodeFenceUntouched() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let body = "```\n[[Home]]\n```\nand [[Home]] outside."
        let out = try LinkUnlinker.unlink(
            in: body,
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "```\n[[Home]]\n```\nand Home outside.")
    }

    @Test func leavesChatLinksUntouched() throws {
        let chatID = "01HCCCCCCCCCCCCCCCCCCCCCCC"
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try LinkUnlinker.unlink(
            in: "[[chat:\(chatID)]] and [[Home]]",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "[[chat:\(chatID)]] and Home")
    }

    @Test func unlinksMultipleOccurrencesInOnePass() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID, "Keep": keepID])
        let out = try LinkUnlinker.unlink(
            in: "[[Home]] then [[Keep]] then [[Home|alias]]",
            unlinkPageIDs: [PageID(rawValue: homeID)],
            unlinkSourceIDs: [],
            resolvePageName: rp, resolveSourceName: rs)
        #expect(out == "Home then [[Keep]] then alias")
    }
}
