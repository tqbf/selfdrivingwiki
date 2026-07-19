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

    // MARK: - Issue #619 — pipe in source/page/chat name (try-resolve-whole)

    @Test func canonicalizesSourceLinkWithEmbeddedPipe() throws {
        // The reported repro: a YouTube title shipped with ` | ` lands as a
        // `source:` link. Without the try-resolve-whole path, the regex splits
        // `name | rest` into target=`name` (truncated) + alias=`rest`, and the
        // source never resolves. With the fix, the whole `name | rest` resolves
        // against the store and is canonicalized as a single target whose
        // auto-alias is the whole display name.
        let name = "But what is cross-entropy? | Compression is Intelligence Part 2"
        let (rp, rs) = resolvers(sources: [name: paperID])
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[source:\(name)]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[source:\(paperID)|\(name)]]")
    }

    @Test func canonicalizesSourceLinkWithEmbeddedPipeAndEmbeddedWhitespace() throws {
        // Alias-side leading spaces (the regex captures `[^\]]+` after `|`, so a
        // spaced form yields a leading-space alias) must be normalized away
        // before the whole-name lookup. Regression guard for the
        // `WikiText.normalized(alias)` step inside the try-resolve-whole branch.
        let (rp, rs) = resolvers(sources: ["Foo | Bar": paperID])
        // User wrote `[[source:Foo | Bar]]` — regex captures target=`source:Foo `
        // and alias=` Bar` (NOTE leading space). Whole-name reconstruction
        // must still resolve against `Foo | Bar` (no leading-space store name).
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[source:Foo | Bar]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[source:\(paperID)|Foo | Bar]]")
    }

    @Test func canonicalizesSourceLinkWithEmbeddedPipeNoSpacesAroundPipe() throws {
        // When the display_name literally contains `|` with NO surrounding
        // spaces (e.g. `Foo|Bar`), the unspaced reconstruction must still
        // resolve. The branch tries spaced form first (miss), then the
        // unspaced form (hit).
        let (rp, rs) = resolvers(sources: ["Foo|Bar": paperID])
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[source:Foo|Bar]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[source:\(paperID)|Foo|Bar]]")
    }

    @Test func canonicalizesPageLinkWithEmbeddedPipe() throws {
        // The fix is not source-specific — page links whose TITLE contains `|`
        // resolve too (page is the default kind when no prefix is present).
        let name = "Agentic Static Analysis | C# Security Auditing"
        let (rp, rs) = resolvers(pages: [name: homeID])
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[\(name)]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[page:\(homeID)|\(name)]]")
    }

    @Test func canonicalizesChatLinkWithEmbeddedPipe() throws {
        // Chat resolver gets the same try-resolve-whole treatment via the
        // injected `resolveChat` closure (which defaults to nil elsewhere).
        let name = "Standup | 2026-01-01"
        let rc: (String) throws -> PageID? = { _ in PageID(rawValue: "01JCHATCHATCHATCHATCHATCHAT") }
        let rp: (String) throws -> PageID? = { _ in nil }
        let rs: (String) throws -> PageID? = { _ in nil }
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[chat:\(name)]]", resolvePage: rp, resolveSource: rs, resolveChat: rc)
        #expect(out == "[[chat:01JCHATCHATCHATCHATCHATCHAT|\(name)]]")
    }

    @Test func canonicalizesEmbedWithEmbeddedPipeInSourceName() throws {
        // The `!` embed prefix must survive the try-resolve-whole rewrite —
        // `fullRange` covers the `[[…]]` span only, so the leading `!` is left
        // byte-for-byte where the user put it (the same as the no-alias branch).
        let name = "Figure | Cross Entropy"
        let (rp, rs) = resolvers(sources: [name: paperID])
        let out = try WikiLinkRewriter.canonicalize(
            in: "![[source:\(name)]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "![[source:\(paperID)|\(name)]]")
    }

    @Test func leavesVerbatimWhenEmbeddedPipeDoesNotResolve() throws {
        // AC: existing `[[target|alias]]` syntax where the whole `target | alias`
        // is NOT a real resource name is unchanged — alias split still fires for
        // the (resolvable) target half. (Mirrors `preservesExistingAlias` but
        // with a `|`-bearing candidate that doesn't exist as a name.)
        let (rp, rs) = resolvers(pages: ["Home": homeID])
        // Whole `"Home | the front page"` is not a page; the truncated `"Home"`
        // is — so the regular alias-split path canonicalizes the target slice.
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[Home | the front page]]", resolvePage: rp, resolveSource: rs)
        #expect(out == "[[page:\(homeID)| the front page]]")
    }

    @Test func leavesVerbatimWhenNeitherSpacedNorUnspacedWholeResolves() throws {
        // The try-resolve-whole branch falls through silently when the user's
        // `[[target|alias]]` is a genuine alias link and neither `target|alias`
        // nor `target | alias` is a real resource name. Forward link is then
        // left byte-identical (regular alias-split path also fails because the
        // truncated target doesn't resolve either).
        let (rp, rs) = resolvers()  // empty namespace — nothing resolves
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[source:But what is cross-entropy? | Compression is Intelligence Part 2]]",
            resolvePage: rp, resolveSource: rs)
        #expect(out == nil)  // forward link, unchanged
    }

    @Test func embeddedPipeCanonicalRoundTripsStably() throws {
        // AC: after canonicalization, the resulting `[[source:<ULID>|name|pipe]]`
        // re-parses + re-canonicalizes as a no-op (ULID is pipe-free; the alias
        // group `[^\]]+` accepts `|`). The idempotency fast path holds.
        let name = "But what is cross-entropy? | Compression is Intelligence Part 2"
        let (rp, rs) = resolvers(sources: [name: paperID])
        let once = try WikiLinkRewriter.canonicalize(
            in: "[[source:\(name)]]", resolvePage: rp, resolveSource: rs)!
        let twice = try WikiLinkRewriter.canonicalize(in: once, resolvePage: rp, resolveSource: rs)
        #expect(twice == nil)  // second pass is a no-op
        #expect(once == "[[source:\(paperID)|\(name)]]")
    }

    @Test func embeddedPipeWithQuotedFragmentStillResolvesBareName() throws {
        // Regression guard for the `#"…"` quoted-anchor path through canonicalize
        // (the parser's `#"first option | second option"` absorption is already
        // covered in `WikiLinkParserTests`). When the `|` lives INSIDE a quoted
        // anchor, the regex absorbs it (no alias split), so `rawAlias == nil`
        // and the try-resolve-whole branch is correctly skipped — today's
        // behavior (resolve bare name, carry the fragment into the canonical
        // target, auto-insert `|<bareTarget>`) is unchanged.
        let (rp, rs) = resolvers(sources: ["Some Page": paperID])
        let out = try WikiLinkRewriter.canonicalize(
            in: "[[source:Some Page#\"first option | second option\"]]",
            resolvePage: rp, resolveSource: rs)
        #expect(out == "[[source:\(paperID)#\"first option | second option\"|Some Page]]")
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
