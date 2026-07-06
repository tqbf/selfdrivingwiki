import Foundation
import Testing
@testable import WikiFSCore

/// Phase 6 — version pinning (`@vN`): pure-layer tests.
/// AC.1 (parse), AC.2 (canonicalize), AC.5 (linkify emit).
struct Phase6PinningPureTests {

    // Valid 26-char Crockford Base32 ids (confusable I/L/O/U absent).
    private let paperID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"
    private let pinID = "01JYYYYYYYYYYYYYYYYYYYYYYY"

    // MARK: - AC.1 — splitVersionPin + ParsedLink.versionPin

    @Test func splitVersionPinStripsTrailingAtV() {
        let (bare, pin) = WikiLinkParser.splitVersionPin("Name@v3")
        #expect(bare == "Name")
        #expect(pin == "3")
    }

    @Test func splitVersionPinCaseInsensitiveV() {
        let (bare, pin) = WikiLinkParser.splitVersionPin("Name@V3")
        #expect(bare == "Name")
        #expect(pin == "3")
    }

    @Test func splitVersionPinNoPinReturnsNil() {
        let (bare, pin) = WikiLinkParser.splitVersionPin("Plain Name")
        #expect(bare == "Plain Name")
        #expect(pin == nil)
    }

    @Test func splitVersionPinInvalidFormsYieldNil() {
        // @v with no digits, @x3 (not v), @v3x (trailing junk).
        for invalid in ["Name@v", "Name@x3", "Name@v3x"] {
            let (bare, pin) = WikiLinkParser.splitVersionPin(invalid)
            #expect(bare == invalid, "bare should be unchanged for \(invalid)")
            #expect(pin == nil, "pin should be nil for \(invalid)")
        }
    }

    @Test func parsesSourceVersionPin() {
        let links = WikiLinkParser.parse("[[source:X@v3]]")
        #expect(links.count == 1)
        #expect(links[0].target == "X")
        #expect(links[0].versionPin == "3")
    }

    @Test func parsesSourceVersionPinWithQuote() {
        let links = WikiLinkParser.parse(#"[[source:X@v3#"a quote"]]"#)
        #expect(links.count == 1)
        #expect(links[0].target == "X")
        #expect(links[0].versionPin == "3")
        #expect(links[0].fragment == #""a quote""#)
    }

    @Test func parsesEmbedVersionPin() {
        let links = WikiLinkParser.parse("![[source:X@v3]]")
        #expect(links.count == 1)
        #expect(links[0].isEmbed == true)
        #expect(links[0].versionPin == "3")
    }

    @Test func unpinnedLinkHasNilVersionPin() {
        let links = WikiLinkParser.parse("[[source:X]]")
        #expect(links.count == 1)
        #expect(links[0].versionPin == nil)
    }

    @Test func distinctPinsAreDistinctOccurrences() {
        // @v3 and @v5 to the same source are TWO occurrences (dedup key includes pin).
        let links = WikiLinkParser.parse("[[source:X@v3]] and [[source:X@v5]]")
        #expect(links.count == 2)
        #expect(links[0].versionPin == "3")
        #expect(links[1].versionPin == "5")
    }

    @Test func samePinDeduplicates() {
        // Two identical pinned links dedupe to one (first occurrence).
        let links = WikiLinkParser.parse("[[source:X@v3]] and [[source:X@v3|alias]]")
        #expect(links.count == 1)
    }

    // MARK: - AC.2 — canonicalize preserves @vN

    private func resolvers(pages: [String: String] = [:], sources: [String: String] = [:])
        -> (resolvePage: (String) throws -> PageID?, resolveSource: (String) throws -> PageID?) {
        let rp: (String) throws -> PageID? = { pages[$0].map { PageID(rawValue: $0) } }
        let rs: (String) throws -> PageID? = { sources[$0].map { PageID(rawValue: $0) } }
        return (rp, rs)
    }

    @Test func canonicalizeNameToULIDPreservesPin() throws {
        let (rp, rs) = resolvers(sources: ["Video": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: #"[[source:Video@v3#"q"]]"#,
                                                      resolvePage: rp, resolveSource: rs)
        #expect(out == #"[[source:\#(paperID)@v3#"q"|Video]]"#)
    }

    @Test func canonicalizeULIDPinIsIdempotent() throws {
        let (rp, rs) = resolvers(sources: ["Video": paperID])
        let body = #"[[source:\#(paperID)@v3#"q"|Name]]"#
        let first = try WikiLinkRewriter.canonicalize(in: body, resolvePage: rp, resolveSource: rs)
        // Already canonical → no change (nil).
        #expect(first == nil)
    }

    @Test func canonicalizePreservesAliasAndPin() throws {
        let (rp, rs) = resolvers(sources: ["Video": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "[[source:Video@v3|My Video]]",
                                                      resolvePage: rp, resolveSource: rs)
        #expect(out == "[[source:\(paperID)@v3|My Video]]")
    }

    @Test func canonicalizePreservesOutOfRangePin() throws {
        let (rp, rs) = resolvers(sources: ["Video": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "[[source:Video@v9]]",
                                                      resolvePage: rp, resolveSource: rs)
        // Out-of-range ordinal is preserved as-written (not validated here).
        #expect(out == "[[source:\(paperID)@v9|Video]]")
    }

    @Test func canonicalizeEmbedPreservesPin() throws {
        let (rp, rs) = resolvers(sources: ["Video": paperID])
        let out = try WikiLinkRewriter.canonicalize(in: "![[source:Video@v3]]",
                                                      resolvePage: rp, resolveSource: rs)
        #expect(out == "![[source:\(paperID)@v3|Video]]")
    }

    // MARK: - AC.5 — linkify emits &pin= for quote links only

    @Test func linkifyPinnedQuoteEmitsPin() {
        let sourceID = PageID(rawValue: paperID)
        let body = #"[[source:\#(paperID)@v3#"a quote"|Paper]]"#
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .source && id == sourceID ? "Paper" : nil },
            pinnedExtractionID: { src, ord in src == sourceID && ord == 3 ? PageID(rawValue: pinID) : nil })
        #expect(out.contains("wiki://source?id=\(paperID)&title="))
        #expect(out.contains("&pin=\(pinID)"))
    }

    @Test func linkifyPinnedNoQuoteOmitsPin() {
        // A pinned link WITHOUT a fragment opens HEAD — no &pin=.
        let sourceID = PageID(rawValue: paperID)
        let body = "[[source:\(paperID)@v3|Paper]]"
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .source && id == sourceID ? "Paper" : nil },
            pinnedExtractionID: { _, _ in PageID(rawValue: pinID) })
        #expect(out.contains("wiki://source?id=\(paperID)&title="))
        #expect(!out.contains("&pin="))
    }

    @Test func linkifyPinnedQuoteOutOfRangeOmitsPin() {
        // When pinnedExtractionID returns nil (ordinal out of range), no &pin=.
        let sourceID = PageID(rawValue: paperID)
        let body = #"[[source:\#(paperID)@v9#"q"|Paper]]"#
        let out = WikiLinkMarkdown.linkified(body,
            isResolved: { _, _ in true },
            displayName: { id, kind in kind == .source && id == sourceID ? "Paper" : nil },
            pinnedExtractionID: { _, _ in nil })
        #expect(!out.contains("&pin="))
    }
}
