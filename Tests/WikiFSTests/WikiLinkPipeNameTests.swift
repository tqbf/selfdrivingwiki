import Foundation
import Testing
@testable import WikiFSCore

/// Pipe-in-name coverage across the pure link pipeline (issues #619, #1225).
///
/// A display name can contain a literal `|` (YouTube titles the app ingests,
/// doc-set names), but the shared `[[…]]` grammar treats the first unquoted
/// `|` as the alias separator. These tests pin the split behavior at every
/// pure seam — span scanning, parsing, the reconstruction-candidate helper,
/// and the typed syntax overlay — that the resolver/renderer seams build on.
/// Resolution-level behavior lives in `WikiLinkMarkdownTests` (compatibility
/// linkifier), `WikiLinkCanonicalizerTests` (canonicalize seam), and the
/// app-target `DocumentEmbedResolverTests` (the production typed renderer).
struct WikiLinkPipeNameTests {

    /// Valid 26-char Crockford Base32 ids (no I/L/O/U).
    private let paperID = "01JZZZZZZZZZZZZZZZZZZZZZZZ"

    private static let pipeTitle = "What is Malleable Software Now | Bryan Min (02-27-2026)"

    // MARK: - Span scanning (WikiLinkSpan)

    @Test func spanSplitsAtFirstUnquotedPipe() {
        let body = "[[Alpha | Beta]]"
        let ns = body as NSString
        let match = WikiLinkSpan.matches(in: body)[0]
        #expect(ns.substring(with: match.targetRange) == "Alpha ")
        #expect(ns.substring(with: match.aliasRange) == " Beta")
    }

    @Test func spanSecondPipeStaysInAlias() {
        let ns = "[[Alpha | Beta | Gamma]]" as NSString
        let match = WikiLinkSpan.matches(in: "[[Alpha | Beta | Gamma]]")[0]
        #expect(ns.substring(with: match.targetRange) == "Alpha ")
        #expect(ns.substring(with: match.aliasRange) == " Beta | Gamma")
    }

    @Test func spanPipeInsideQuoteAnchorStaysInAlias() {
        // The `#"…"` quote anchor is a quoted run: a `|` inside it must not
        // start the alias. The alias starts at the UNQUOTED pipe.
        let body = "[[source:Name | Other#\"a | b\"]]"
        let ns = body as NSString
        let match = WikiLinkSpan.matches(in: body)[0]
        #expect(ns.substring(with: match.targetRange) == "source:Name ")
        #expect(ns.substring(with: match.aliasRange) == " Other#\"a | b\"")
    }

    @Test func spanWholePipeNameWithQuoteSuffixSplitsAtNamePipe() {
        // The exact shape stored in real bodies (issue #1225): the pipe inside
        // the title is unquoted, so the scanner splits there and the quote
        // anchor rides along in the alias portion.
        let body = "[[source:\(Self.pipeTitle)#\"a quoted passage\"]]"
        let ns = body as NSString
        let match = WikiLinkSpan.matches(in: body)[0]
        #expect(ns.substring(with: match.targetRange) == "source:What is Malleable Software Now ")
        #expect(ns.substring(with: match.aliasRange) == " Bryan Min (02-27-2026)#\"a quoted passage\"")
    }

    // MARK: - Parsing (WikiLinkParser.parse)

    @Test func parseTruncatesPipeNameAtGrammarLevel() {
        // Documented grammar behavior: parse sees the split target and the
        // alias text. (Resolution-level healing happens in the resolver,
        // canonicalize, and renderer seams — never here.)
        let links = WikiLinkParser.parse("See [[source:\(Self.pipeTitle)]].")
        #expect(links.count == 1)
        #expect(links[0].linkType == .source)
        #expect(links[0].target == "What is Malleable Software Now")
        #expect(links[0].linkText == "Bryan Min (02-27-2026)")
    }

    @Test func parseKeepsQuoteAnchorInAliasText() {
        let body = "[[source:\(Self.pipeTitle)#\"a quoted passage\"]]"
        let links = WikiLinkParser.parse(body)
        #expect(links.count == 1)
        #expect(links[0].target == "What is Malleable Software Now")
        // The fragment is part of the alias slice at parse level; it only
        // becomes a real fragment after reconstruction peels it off.
        #expect(links[0].fragment == nil)
        #expect(links[0].linkText == "Bryan Min (02-27-2026)#\"a quoted passage\"")
    }

    // MARK: - Reconstruction candidates (WikiLinkResolver)

    @Test func reconstructionCandidatesSpacedThenUnspaced() {
        #expect(
            WikiLinkResolver.pipeReconstructionCandidates(bare: "Foo", alias: "Bar")
                == ["Foo | Bar", "Foo|Bar"])
    }

    @Test func reconstructionCandidatesNormalizeAliasAndAppendFragment() {
        #expect(
            WikiLinkResolver.pipeReconstructionCandidates(
                bare: "Foo", alias: "  Bar  ", fragment: "\"quote\"")
                == ["Foo | Bar#\"quote\"", "Foo|Bar#\"quote\""])
    }

    @Test func reconstructionCandidatesEmptyAliasYieldNothing() {
        #expect(WikiLinkResolver.pipeReconstructionCandidates(bare: "Foo", alias: "   ") == [])
        #expect(WikiLinkResolver.pipeReconstructionCandidates(bare: "Foo", alias: "") == [])
    }

    @Test func reconstructionCandidatesResolveThroughResolvedSplit() {
        // The whole point of the helper: `resolvedSplit` peels the alias-
        // carried quote anchor off the reconstructed name, and `isKnown` sees
        // the full display name.
        let candidates = WikiLinkResolver.pipeReconstructionCandidates(
            bare: "What is Malleable Software Now",
            alias: "Bryan Min (02-27-2026)#\"a quoted passage\"")
        var tried: [String] = []
        let split = candidates.compactMap { candidate -> WikiLinkResolver.Split? in
            tried.append(candidate)
            return WikiLinkResolver.resolvedSplit(of: candidate) { $0 == Self.pipeTitle }
        }.first
        #expect(tried.first == "What is Malleable Software Now | Bryan Min (02-27-2026)#\"a quoted passage\"")
        #expect(split?.base == Self.pipeTitle)
        #expect(split?.fragment == "\"a quoted passage\"")
    }

    // MARK: - Typed syntax overlay (syntaxNodes) — the resolver's input

    @Test func syntaxNodesPipeNameCarriesTruncatedLiteralAndAlias() throws {
        let body = "[[source:\(Self.pipeTitle)#\"a quoted passage\"]]"
        guard case .link(let link) = try #require(WikiLinkParser.syntaxNodes(in: body).first) else {
            Issue.record("Expected a link node")
            return
        }
        #expect(link.target.namespace == .source)
        #expect(link.target.literal == "What is Malleable Software Now")
        #expect(link.target.canonicalID == nil)
        // The quote anchor landed in the ALIAS slice, so the target carries no
        // fragment — reconstruction must peel it from the candidate text.
        #expect(link.target.fragment == nil)
        #expect(link.alias == "Bryan Min (02-27-2026)#\"a quoted passage\"")
        #expect(link.displayText == "Bryan Min (02-27-2026)#\"a quoted passage\"")
    }

    @Test func syntaxNodesCanonicalULIDLinkKeepsFullPipeAlias() throws {
        // After canonicalization the body reads
        // `[[source:<ULID>|<full title>]]`: the FIRST pipe (after the ULID) is
        // the alias separator and the title's own pipe survives inside the
        // alias. This is the invariant that makes id-backed links render the
        // full display label without any reconstruction.
        let body = "[[source:\(paperID)|\(Self.pipeTitle)]]"
        guard case .link(let link) = try #require(WikiLinkParser.syntaxNodes(in: body).first) else {
            Issue.record("Expected a link node")
            return
        }
        #expect(link.target.canonicalID == paperID)
        #expect(link.alias == Self.pipeTitle)
        #expect(link.displayText == Self.pipeTitle)
    }
}
