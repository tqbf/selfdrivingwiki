import Foundation
import Testing
@testable import WikiFSCore

/// Pure unit tests for `WikiLinkRewriter.canonicalize` (Phase 5) and
/// `WikiLinkParser.isCanonicalULID`. Covers AC.2 (alias, fragment, embed,
/// code-fence preservation), AC.4 (idempotency), and the ULID predicate.
struct WikiLinkCanonicalizerTests {

    // Valid 26-char Crockford Base32 ids (the confusable I/L/O/U are absent).
    private let homeID = "01HXXXXXXXXXXXXXXXXXXXXXXX"
    private let alphaID = "01HYYYYYYYYYYYYYYYYYYYYYYY"
    private let paperID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"

    /// Build resolver closures from name→id maps (non-throwing satisfies the
    /// `throws -> PageID?` requirement).
    private func resolvers(pages: [String: String] = [:], sources: [String: String] = [:])
        -> (resolvePage: (String) throws -> PageID?, resolveSource: (String) throws -> PageID?) {
        let rp: (String) throws -> PageID? = { pages[$0].map { PageID(rawValue: $0) } }
        let rs: (String) throws -> PageID? = { sources[$0].map { PageID(rawValue: $0) } }
        return (rp, rs)
    }

    // MARK: - Basic canonicalization

    @Test func canonicalizesPageLink() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try WikiLinkRewriter.canonicalize(in: "See [[Home]] now.", resolvePage: rp, resolveSource: rs)
        #expect(out == "See [[page:\(homeID)|Home]] now.")
    }

    @Test func canonicalizesSourceLink() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "Cite [[source:Paper]].", resolvePage: rp, resolveSource: rs)
        #expect(out == "Cite [[source:\(paperID)|Paper]].")
    }

    @Test func canonicalizesExplicitPagePrefix() throws {
        let (rp, rs) = resolvers(pages: ["Alpha": alphaID])
        let out = try WikiLinkRewriter.canonicalize(in: "[[page:Alpha]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[page:\(alphaID)|Alpha]]")
    }

    // MARK: - AC.2 — alias, fragment, embed, code-fence preservation

    @Test func preservesExistingAlias() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try WikiLinkRewriter.canonicalize(in: "[[Home|alias text]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[page:\(homeID)|alias text]]")
    }

    @Test func preservesQuoteFragment() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "[[source:Paper#\"quote\"]]",
                                                     resolvePage: rp, resolveSource: rs)
        // Fragment preserved in the target; alias inserted = bare name.
        #expect(out == "[[source:\(paperID)#\"quote\"|Paper]]")
    }

    @Test func preservesEmbedPrefix() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "![[source:Paper]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "![[source:\(paperID)|Paper]]")
    }

    @Test func preservesEmbedPrefixWithAlias() throws {
        let (rp, rs) = resolvers(sources: ["Paper": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "![[source:Paper|the figure]]",
                                                     resolvePage: rp, resolveSource: rs)
        #expect(out == "![[source:\(paperID)|the figure]]")
    }

    @Test func leavesCodeFenceUntouched() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let body = "```\n[[Home]]\n```\nand [[Home]] outside."
        let out = try WikiLinkRewriter.canonicalize(in: body, resolvePage: rp, resolveSource: rs)
        #expect(out == "```\n[[Home]]\n```\nand [[page:\(homeID)|Home]] outside.")
    }

    @Test func leavesInlineCodeSpanUntouched() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try WikiLinkRewriter.canonicalize(in: "Use `[[Home]]` but [[Home]] links.",
                                                     resolvePage: rp, resolveSource: rs)
        #expect(out == "Use `[[Home]]` but [[page:\(homeID)|Home]] links.")
    }

    // MARK: - AC.3 — forward links left as-written

    @Test func leavesUnresolvedLinkVerbatim() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try WikiLinkRewriter.canonicalize(in: "[[No Such Page]] and [[Home]]",
                                                     resolvePage: rp, resolveSource: rs)
        #expect(out == "[[No Such Page]] and [[page:\(homeID)|Home]]")
    }

    @Test func returnsNilWhenNothingChanged() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let out = try WikiLinkRewriter.canonicalize(in: "No links here.", resolvePage: rp, resolveSource: rs)
        #expect(out == nil)
    }

    // MARK: - AC.4 — idempotency

    @Test func canonicalizingAlreadyCanonicalIsNoOp() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID], sources: ["Paper": paperID])
        let canonical = "See [[page:\(homeID)|Home]] and [[source:\(paperID)|Paper]]."
        let out = try WikiLinkRewriter.canonicalize(in: canonical, resolvePage: rp, resolveSource: rs)
        #expect(out == nil)
    }

    @Test func doubleCanonicalizeStable() throws {
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        let once = try WikiLinkRewriter.canonicalize(in: "[[Home]]", resolvePage: rp, resolveSource: rs)!
        let twice = try WikiLinkRewriter.canonicalize(in: once, resolvePage: rp, resolveSource: rs)
        #expect(twice == nil)
        #expect(once == "[[page:\(homeID)|Home]]")
    }

    // MARK: - isCanonicalULID

    @Test func isCanonicalULIDAcceptsValid() {
        #expect(WikiLinkParser.isCanonicalULID(homeID))
        #expect(WikiLinkParser.isCanonicalULID(paperID))
    }

    @Test func isCanonicalULIDRejectsWrongLength() {
        #expect(!WikiLinkParser.isCanonicalULID("01HXX"))
        #expect(!WikiLinkParser.isCanonicalULID(String(repeating: "X", count: 25)))
        #expect(!WikiLinkParser.isCanonicalULID(String(repeating: "X", count: 27)))
    }

    @Test func isCanonicalULIDRejectsNonCrockford() {
        // I, L, O, U are absent from Crockford Base32.
        #expect(!WikiLinkParser.isCanonicalULID("01HIIIIIIIIIIIIIIIIIIIIIIII"))
        #expect(!WikiLinkParser.isCanonicalULID("01HLLLLLLLLLLLLLLLLLLLLLLLL"))
        #expect(!WikiLinkParser.isCanonicalULID("01HOOOOOOOOOOOOOOOOOOOOOOOO"))
        #expect(!WikiLinkParser.isCanonicalULID("01HUUUUUUUUUUUUUUUUUUUUUUUU"))
    }

    @Test func isCanonicalULIDRejectsLowercase() {
        // The encoder always emits uppercase; a lowercase ULID is never canonical
        // (id lookups are case-sensitive, so accepting lowercase would render a
        // ghost). Reject it so it resolves by name instead.
        #expect(!WikiLinkParser.isCanonicalULID(homeID.lowercased()))
    }
}
