import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the pure `[[wiki-link]]` → Markdown-link transform that powers
/// the in-app preview. No view, no store: resolution is injected as a closure.
struct WikiLinkMarkdownTests {

    // MARK: - Basic forms

    @Test func simpleLinkBecomesMarkdownLink() {
        let out = WikiLinkMarkdown.linkified("See [[Home]] now.")
        #expect(out == "See [Home](wiki://page?title=Home) now.")
    }

    @Test func aliasedLinkUsesAliasTextAndTargetURL() {
        let out = WikiLinkMarkdown.linkified("See [[Calvin Cycle|the cycle]].")
        #expect(out == "See [the cycle](wiki://page?title=Calvin%20Cycle).")
    }

    @Test func multipleLinksInOneBody() {
        let out = WikiLinkMarkdown.linkified("[[Alpha]] and [[Beta|B]] and [[Gamma]]")
        #expect(out == "[Alpha](wiki://page?title=Alpha) and "
            + "[B](wiki://page?title=Beta) and "
            + "[Gamma](wiki://page?title=Gamma)")
    }

    @Test func duplicateTargetsAreEachRewrittenInPlace() {
        // Unlike WikiLinkParser (which de-dupes for the graph), the transform must
        // rewrite EVERY occurrence so all of them are clickable in the preview.
        let out = WikiLinkMarkdown.linkified("[[Home]] then [[Home]] again")
        #expect(out == "[Home](wiki://page?title=Home) then "
            + "[Home](wiki://page?title=Home) again")
    }

    // MARK: - URL encoding

    @Test func spacesInTitleArePercentEncoded() {
        let out = WikiLinkMarkdown.linkified("[[Photosynthesis Overview]]")
        #expect(out == "[Photosynthesis Overview](wiki://page?title=Photosynthesis%20Overview)")
    }

    @Test func queryMetacharactersInTitleAreEncoded() {
        // The first `#` splits fragment from base (markdown-anchors §1).
        // "A&B=C?D#E+F" → base:"A&B=C?D", fragment:"E+F".
        let out = WikiLinkMarkdown.linkified("[[A&B=C?D#E+F]]") { name, _ in name == "A&B=C?D" }
        let url = URL(string: extractURL(out))!
        let title = WikiLinkMarkdown.target(from: url)
        let frag = WikiLinkMarkdown.fragment(from: url)
        #expect(title == "A&B=C?D")
        #expect(frag == "E+F")
    }

    @Test func whitespaceInTargetIsCollapsedLikeTheParser() {
        let out = WikiLinkMarkdown.linkified("[[  Home   Page  ]]")
        #expect(out == "[Home Page](wiki://page?title=Home%20Page)")
    }

    // MARK: - Resolution / styling host

    @Test func unresolvedTargetUsesMissingHost() {
        let out = WikiLinkMarkdown.linkified("[[Ghost]]") { _, _ in false }
        #expect(out == "[Ghost](wiki://missing?title=Ghost)")
    }

    @Test func mixedResolutionPicksHostPerLink() {
        let out = WikiLinkMarkdown.linkified("[[Real]] vs [[Fake]]") { name, _ in name == "Real" }
        #expect(out == "[Real](wiki://page?title=Real) vs "
            + "[Fake](wiki://missing?title=Fake)")
    }

    // MARK: - Code-span / fence protection

    @Test func inlineCodeSpanIsNotLinkified() {
        let out = WikiLinkMarkdown.linkified("Use `[[Home]]` literally, but [[Home]] links.")
        #expect(out == "Use `[[Home]]` literally, but [Home](wiki://page?title=Home) links.")
    }

    @Test func fencedCodeBlockIsNotLinkified() {
        let body = """
        Before [[Real]]

        ```
        code with [[NotALink]] inside
        ```

        After [[Also]]
        """
        let out = WikiLinkMarkdown.linkified(body)
        #expect(out.contains("[Real](wiki://page?title=Real)"))
        #expect(out.contains("[Also](wiki://page?title=Also)"))
        // The fenced content stays verbatim.
        #expect(out.contains("code with [[NotALink]] inside"))
        #expect(!out.contains("NotALink](wiki"))
    }

    @Test func doubleBacktickSpanProtectsSingleBacktickInside() {
        let out = WikiLinkMarkdown.linkified("``[[A]] `tick` [[B]]`` and [[C]]")
        // Everything inside the `` … `` span is literal; only [[C]] links.
        #expect(out.contains("``[[A]] `tick` [[B]]``"))
        #expect(out.contains("[C](wiki://page?title=C)"))
        #expect(!out.contains("[A](wiki"))
        #expect(!out.contains("[B](wiki"))
    }

    // MARK: - Edge cases

    @Test func emptyTargetIsLeftLiteral() {
        #expect(WikiLinkMarkdown.linkified("[[]] and [[   ]]") == "[[]] and [[   ]]")
    }

    @Test func bodyWithoutLinksIsUnchanged() {
        let body = "Plain **markdown** with a [normal](https://x.test) link."
        #expect(WikiLinkMarkdown.linkified(body) == body)
    }

    @Test func displayBracketsAreEscapedSoTheyDontBreakMarkdown() {
        // The grammar forbids `]` in an alias, but a `[` is allowed and would
        // otherwise be read as the start of a nested Markdown link; escape it.
        let out = WikiLinkMarkdown.linkified("[[Home|a [b c]]")
        #expect(out == "[a \\[b c](wiki://page?title=Home)")
    }

    @Test func idempotenceOnAlreadyLinkifiedOutput() {
        // The output has no `[[…]]`, so a second pass changes nothing.
        let once = WikiLinkMarkdown.linkified("[[Home]] and [[Away]]")
        #expect(WikiLinkMarkdown.linkified(once) == once)
    }

    // MARK: - URL round-trip helpers

    @Test func targetExtractsTitleFromOurURLs() {
        let resolved = URL(string: "wiki://page?title=Calvin%20Cycle")!
        let missing = URL(string: "wiki://missing?title=Ghost")!
        #expect(WikiLinkMarkdown.target(from: resolved) == "Calvin Cycle")
        #expect(WikiLinkMarkdown.target(from: missing) == "Ghost")
        #expect(WikiLinkMarkdown.isResolvedURL(resolved))
        #expect(!WikiLinkMarkdown.isResolvedURL(missing))
    }

    @Test func targetRejectsForeignURLs() {
        #expect(WikiLinkMarkdown.target(from: URL(string: "https://example.com?title=X")!) == nil)
        #expect(WikiLinkMarkdown.target(from: URL(string: "wiki://page")!) == nil)
    }

    // MARK: - source: link rendering (Phase B)

    @Test func resolvedSourceLinkUsesSourceHost() {
        let out = WikiLinkMarkdown.linkified("[[source:My Notes]]") { _, _ in true }
        #expect(out == "[My Notes](wiki://source?title=My%20Notes)")
    }

    @Test func unresolvedSourceLinkUsesMissingHost() {
        let out = WikiLinkMarkdown.linkified("[[source:Ghost]]") { _, _ in false }
        #expect(out == "[Ghost](wiki://missing?title=Ghost)")
    }

    @Test func sourceLinkWithAliasPreservesDisplay() {
        let out = WikiLinkMarkdown.linkified("[[source:My Notes|the notes]]") { _, _ in true }
        // Display text is the alias, URL carries the target.
        #expect(out.contains("the notes"))
        #expect(out.contains("wiki://source?title=My%20Notes"))
    }

    @Test func resolvedKindReturnsSourceForSourceHost() {
        let url = URL(string: "wiki://source?title=X")!
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .source)
    }

    @Test func resolvedKindReturnsPageForPageHost() {
        let url = URL(string: "wiki://page?title=X")!
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .page)
    }

    @Test func resolvedKindReturnsNilForMissingHost() {
        let url = URL(string: "wiki://missing?title=X")!
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == nil)
    }

    @Test func targetFromAcceptsSourceHost() {
        let url = URL(string: "wiki://source?title=My%20Notes")!
        #expect(WikiLinkMarkdown.target(from: url) == "My Notes")
    }

    @Test func isResolvedURLTrueForSourceHost() {
        #expect(WikiLinkMarkdown.isResolvedURL(URL(string: "wiki://source?title=X")!))
    }

    // MARK: - Mixed page + source links

    @Test func mixedPageAndSourceLinksRenderWithCorrectHosts() {
        let out = WikiLinkMarkdown.linkified("[[Home]] and [[source:Paper]]") { name, kind in
            kind == .source ? name == "Paper" : name == "Home"
        }
        #expect(out.contains("wiki://page?title=Home"))
        #expect(out.contains("wiki://source?title=Paper"))
    }

    @Test func emptySourcePrefixRendersAsLiteral() {
        // [[source:]] should stay verbatim, not become a link.
        let out = WikiLinkMarkdown.linkified("before [[source:]] after") { _, _ in true }
        #expect(out.contains("[[source:]]"))
        #expect(!out.contains("wiki://"))
    }

    // MARK: - Fragment / anchor rendering (markdown-anchors)

    @Test func pageLinkWithHeadingFragmentRendersFragmentInURL() {
        let out = WikiLinkMarkdown.linkified("[[Overview#Methodology]]") { name, _ in name == "Overview" }
        #expect(out == "[Overview](wiki://page?title=Overview#Methodology)")
    }

    @Test func sourceLinkWithQuoteFragmentRendersFragmentInURL() {
        let out = WikiLinkMarkdown.linkified("[[source:Paper#the results]]") { name, _ in name == "Paper" }
        #expect(out == "[Paper](wiki://source?title=Paper#the%20results)")
    }

    @Test func fragmentRoundTripsThroughURL() {
        let out = WikiLinkMarkdown.linkified("[[source:Smith#\"exact passage\"]]") { name, _ in name == "Smith" }
        let url = URL(string: extractURL(out))!
        let frag = WikiLinkMarkdown.fragment(from: url)
        #expect(frag == "\"exact passage\"")
    }

    @Test func fragmentWithUnbalancedParensDoesNotBreakMarkdownLink() {
        // A quoted passage with `1.) 2.) 3.) 4.)` enumerations carries unbalanced
        // `)` characters. The whole URL is emitted inside a Markdown `(url)`
        // destination, so an unencoded `)` would terminate the link early and
        // dump the rest as literal text (breaking the renderer). They must be
        // percent-encoded — and still round-trip back to the original fragment.
        let quote = "it is 1.) outside, 2.) uncontrollable (Bargh, 1994)"
        let out = WikiLinkMarkdown.linkified("[[source:Paper#\"\(quote)\"]]") { name, _ in name == "Paper" }
        // No literal parens survive in the emitted link destination.
        #expect(!extractURL(out).contains("("))
        #expect(!extractURL(out).contains(")"))
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.fragment(from: url) == "\"\(quote)\"")
    }

    @Test func titleWithParensIsEncoded() {
        // Parens in the *title* would equally break the `(url)` destination.
        let out = WikiLinkMarkdown.linkified("[[Title (2024)]]") { _, _ in true }
        #expect(!extractURL(out).contains("("))
        #expect(!extractURL(out).contains(")"))
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Title (2024)")
    }

    @Test func samePageAnchorRendersAsWikiAnchorHost() {
        let out = WikiLinkMarkdown.linkified("[[#Section]]") { _, _ in true }
        #expect(out == "[Section](wiki://anchor#Section)")
    }

    @Test func samePageAnchorWithAliasPreservesDisplay() {
        let out = WikiLinkMarkdown.linkified("[[#Section|click here]]") { _, _ in true }
        #expect(out == "[click here](wiki://anchor#Section)")
    }

    @Test func samePageQuotedAnchorEncodesSpacesAndQuotes() {
        let out = WikiLinkMarkdown.linkified("[[#\"a quote\"]]") { _, _ in true }
        #expect(out.contains("wiki://anchor#"))
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.isSamePageAnchor(url))
    }

    @Test func isSamePageAnchorTrueForAnchorHost() {
        #expect(WikiLinkMarkdown.isSamePageAnchor(URL(string: "wiki://anchor#Section")!))
    }

    @Test func isSamePageAnchorFalseForPageHost() {
        #expect(!WikiLinkMarkdown.isSamePageAnchor(URL(string: "wiki://page?title=X#Section")!))
    }

    @Test func fragmentFromReturnsNilForNonWikiURL() {
        #expect(WikiLinkMarkdown.fragment(from: URL(string: "https://x.com#frag")!) == nil)
    }

    @Test func unresolvedLinkStillCarriesFragment() {
        let out = WikiLinkMarkdown.linkified("[[Ghost#Section]]") { _, _ in false }
        #expect(out == "[Ghost](wiki://missing?title=Ghost#Section)")
    }

    @Test func fragmentWithInnerHashIsEncoded() {
        // "C# is sharp" → inner # is percent-encoded in the URL.
        let out = WikiLinkMarkdown.linkified("[[source:Note#C# is sharp]]") { name, _ in name == "Note" }
        let url = URL(string: extractURL(out))!
        let frag = WikiLinkMarkdown.fragment(from: url)
        #expect(frag == "C# is sharp")
    }

    // MARK: - `#` inside the NAME

    @Test func sourceNameContainingHashWithQuoteAnchorDisplaysFullName() {
        // The "C#" in the name no longer truncates the citation to
        // "…Analysis for C" — the resolver finds the real name.
        let out = WikiLinkMarkdown.linkified(
            "[[source:Agentic Static Analysis for C# Security Auditing (2026)#\"the results\"]]"
        ) { name, _ in name == "Agentic Static Analysis for C# Security Auditing (2026)" }
        #expect(out.hasPrefix("[Agentic Static Analysis for C# Security Auditing (2026)]"))
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url)
                == "Agentic Static Analysis for C# Security Auditing (2026)")
        #expect(WikiLinkMarkdown.fragment(from: url) == "\"the results\"")
    }

    @Test func pageTitleContainingHashResolvesViaFullTitleFallback() {
        // No quote anchor, so the parse splits at the `#` in "C#" — but the
        // FULL target names an existing page, so the fallback links it whole.
        let out = WikiLinkMarkdown.linkified("[[C# Guide]]") { name, kind in
            name == "C# Guide" && kind == .page
        }
        #expect(out.hasPrefix("[C# Guide]"))
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "C# Guide")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .page)
        #expect(url.fragment == nil) // the "# Guide" tail is title, not anchor
    }

    @Test func sourceNameContainingHashWithoutAnchorResolvesViaFallback() {
        let out = WikiLinkMarkdown.linkified("[[source:C# Notes]]") { name, kind in
            name == "C# Notes" && kind == .source
        }
        #expect(out.hasPrefix("[C# Notes]"))
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "C# Notes")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .source)
    }

    @Test func hashTitleFallbackKeepsAliasDisplay() {
        let out = WikiLinkMarkdown.linkified("[[C# Guide|the guide]]") { name, _ in
            name == "C# Guide"
        }
        #expect(out.hasPrefix("[the guide]"))
    }

    @Test func unresolvedHashTitleKeepsBaseAndFragment() {
        // Neither the base nor the full target resolves → unchanged legacy
        // shape: base title + fragment, missing host.
        let out = WikiLinkMarkdown.linkified("[[C# Ghost]]") { _, _ in false }
        #expect(out == "[C](wiki://missing?title=C#%20Ghost)")
    }

    @Test func hashTitleWithRealAnchorResolvesLongestName() {
        // A `#`-containing title AND a real section anchor after it: the
        // longest known name wins, the rest is the anchor.
        let out = WikiLinkMarkdown.linkified("[[C# Guide#Methods]]") { name, _ in
            name == "C# Guide"
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "C# Guide")
        #expect(WikiLinkMarkdown.fragment(from: url) == "Methods")
        #expect(out.hasPrefix("[C# Guide]"))
    }

    @Test func exactFullTitleBeatsAnchorReading() {
        // A page literally titled "Page#Section" wins over Page + anchor.
        let out = WikiLinkMarkdown.linkified("[[Page#Section]]") { name, _ in
            name == "Page#Section" || name == "Page"
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Page#Section")
        #expect(url.fragment == nil)
    }

    // MARK: - Pipe inside the NAME (issue #619 render-path mirror)
    //
    // The regex splits `[[target|alias]]` at the first `|`, but a display
    // name can legitimately contain a literal `|` (YouTube titles the app
    // ingests, doc-set names like "Flex Tier - Documentation | Neuralwatt
    // Cloud"). On the render path used by chat (which never canonicalizes),
    // the split target is truncated and would render as inert
    // `wiki://missing`. The reconstruction below mirrors the canonicalize-seam
    // fix (WikiLinkRewriter.swift:71-126): try `bareTarget | alias` whole
    // through resolvedSplit, emit a navigable link when it resolves.

    @Test func pipeInSourceNameResolvesViaAliasReconstruction() {
        // A source whose display name contains a literal `|`. The regex
        // splits at `|`, but the reconstructed whole name resolves.
        let out = WikiLinkMarkdown.linkified(
            "[[source:Flex Tier - Documentation | Neuralwatt Cloud]]"
        ) { name, kind in
            name == "Flex Tier - Documentation | Neuralwatt Cloud" && kind == .source
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Flex Tier - Documentation | Neuralwatt Cloud")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .source)
    }

    @Test func pipeInSourceNameWithQuoteFragmentResolves() {
        // The chat footnote case: pipe-containing name + #"quote" anchor.
        // The fragment lands in the alias portion after the `|` split; the
        // reconstruction carries it through resolvedSplit.
        let out = WikiLinkMarkdown.linkified(
            "[[source:Flex Tier - Documentation | Neuralwatt Cloud#\"a quoted passage\"]]"
        ) { name, kind in
            name == "Flex Tier - Documentation | Neuralwatt Cloud" && kind == .source
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Flex Tier - Documentation | Neuralwatt Cloud")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .source)
        #expect(WikiLinkMarkdown.fragment(from: url) == "\"a quoted passage\"")
    }

    @Test func pipeInPageNameResolvesViaAliasReconstruction() {
        // Page-side equivalent: a page title containing `|`.
        let out = WikiLinkMarkdown.linkified(
            "[[But what is cross-entropy? | Compression is Intelligence Part 2]]"
        ) { name, kind in
            name == "But what is cross-entropy? | Compression is Intelligence Part 2" && kind == .page
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url)
                == "But what is cross-entropy? | Compression is Intelligence Part 2")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .page)
    }

    @Test func pipeInChatNameResolvesViaAliasReconstruction() {
        // Chat-side equivalent: a chat title containing `|`.
        let out = WikiLinkMarkdown.linkified(
            "[[chat:Standup - 2026-01-15 | Project Alpha]]"
        ) { name, kind in
            name == "Standup - 2026-01-15 | Project Alpha" && kind == .chat
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Standup - 2026-01-15 | Project Alpha")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .chat)
    }

    @Test func genuineAliasUnaffectedByPipeReconstruction() {
        // `[[Alpha|B]]` where Alpha exists and "Alpha | B" does NOT: the
        // reconstruction fails, falls through to the normal path, resolves Alpha.
        let out = WikiLinkMarkdown.linkified("[[Alpha|B]]") { name, _ in
            name == "Alpha"
        }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Alpha")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .page)
    }

    @Test func pipeReconstructionFallsThroughToMissingWhenUnresolved() {
        // Neither the truncated target nor the reconstructed whole resolves:
        // falls through to today's behavior — `wiki://missing`, no navigation.
        let out = WikiLinkMarkdown.linkified("[[source:Ghost | Pipeline]]") { _, _ in false }
        let url = URL(string: extractURL(out))!
        #expect(WikiLinkMarkdown.target(from: url) == "Ghost")
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == nil)
        #expect(out.contains("wiki://missing"))
    }

    // MARK: - Code-span protection for source links

    @Test func sourceLinkInsideCodeSpanIsLiteral() {
        let out = WikiLinkMarkdown.linkified("`[[source:Paper]]` is a code span") { _, _ in true }
        #expect(out.contains("[[source:Paper]]"))
        #expect(!out.contains("wiki://source"))
    }

    @Test func sourceLinkInsideFencedCodeBlockIsLiteral() {
        let out = WikiLinkMarkdown.linkified(
            "```\n[[source:Paper]]\n```\n\nOutside [[source:Notes]]") { _, _ in true }
        #expect(out.contains("[[source:Paper]]"))   // inside fence → verbatim
        #expect(!out.contains("wiki://source?title=Paper"))
        #expect(out.contains("wiki://source?title=Notes")) // outside fence → linkified
    }

    // MARK: - Backticks nested INSIDE the link anchor text (issue #117)

    @Test func sourceLinkWithBacktickCodeInQuotedFragmentStillLinkifies() {
        // The old check flagged the link as "inside a code span" whenever its
        // range merely INTERSECTED a backtick span, which is also true of the
        // opposite nesting (code inside the link's quoted anchor text). Only
        // full containment (code span wraps the whole link) should suppress it.
        let out = WikiLinkMarkdown.linkified(
            "[^minimize]: [[source:SwiftUI New Toolbar Features#\"The `.minimize` behavior "
            + "renders the search field as a button-like control.\"]]"
        ) { _, _ in true }
        #expect(out.contains("wiki://source?title=SwiftUI%20New%20Toolbar%20Features"))
        #expect(!out.contains("[[source:"))
    }

    @Test func linkStillProtectedWhenTrulyNestedInsideCodeSpan() {
        // The reverse nesting — a link written inside backticks — must still
        // stay literal; only the containment direction flips the outcome.
        let out = WikiLinkMarkdown.linkified("Use `[[Home]]` literally.") { _, _ in true }
        #expect(out.contains("`[[Home]]`"))
        #expect(!out.contains("wiki://page?title=Home"))
    }

    // MARK: - Embed rendering `![[source:…]]` (Phase 4a, AC.4)

    @Test func embedImageRendersAsImgTag() {
        let id = PageID(rawValue: "01HTESTIMG0000000000000001")
        let out = WikiLinkMarkdown.linkified(
            "![[source:img.png]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "image/png") }
        )
        #expect(out.contains("<img"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
        #expect(out.contains("class=\"wiki-embed\""))
        #expect(!out.contains("wiki://"))  // not a fallback cite link
    }

    @Test func embedVideoRendersAsVideoTag() {
        let id = PageID(rawValue: "01HTESTVID00000000000000002")
        let out = WikiLinkMarkdown.linkified(
            "![[source:clip.mp4]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "video/mp4") }
        )
        #expect(out.contains("<video"))
        #expect(out.contains("controls"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
    }

    @Test func embedAudioRendersAsAudioTag() {
        let id = PageID(rawValue: "01HTESTAUD00000000000000003")
        let out = WikiLinkMarkdown.linkified(
            "![[source:song.mp3]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "audio/mpeg") }
        )
        #expect(out.contains("<audio"))
        #expect(out.contains("controls"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
    }

    @Test func embedPdfRendersAsIframe() {
        let id = PageID(rawValue: "01HTESTPDF00000000000000004")
        let out = WikiLinkMarkdown.linkified(
            "![[source:doc.pdf]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "application/pdf") }
        )
        #expect(out.contains("<iframe"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
    }

    @Test func embedUnresolvedSourceFallsBackToCiteLink() {
        // embedInfo returns nil → fallback to a cite link (ghost styling).
        let out = WikiLinkMarkdown.linkified(
            "![[source:Ghost]]",
            isResolved: { _, _ in false },
            embedInfo: { _ in nil }
        )
        #expect(out.contains("wiki://missing"))
        #expect(!out.contains("<img"))
    }

    @Test func embedUnknownMimeFallsBackToCiteLink() {
        // Source resolves but MIME is not renderable (e.g. text/plain).
        let id = PageID(rawValue: "01HTESTTXT00000000000000005")
        let out = WikiLinkMarkdown.linkified(
            "![[source:notes.txt]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "text/plain") }
        )
        #expect(out.contains("wiki://source"))
        #expect(!out.contains("<img"))
        #expect(!out.contains("<video"))
    }

    @Test func embedWithNoResolverFallsBackToCiteLink() {
        // No embedInfo passed → fallback to cite link.
        let out = WikiLinkMarkdown.linkified(
            "![[source:img.png]]",
            isResolved: { _, _ in true }
        )
        #expect(out.contains("wiki://source"))
        #expect(!out.contains("<img"))
    }

    // MARK: - Byteless external-embed targets (Phase 4b, AC.1/AC.2/AC.4)

    @Test func embedProviderIframeTargetRendersIframe() {
        let id = PageID(rawValue: "01HTESTYT0000000000000000A")
        let target = EmbedTarget(kind: .iframe, url: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
        let out = WikiLinkMarkdown.linkified(
            "![[source:video]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "video/youtube", target: target) }
        )
        #expect(out.contains("<iframe"))
        #expect(out.contains("youtube-nocookie.com/embed/dQw4w9WgXcQ"))
        #expect(out.contains("wiki-embed"))
        // YouTube iframes are eager-loaded (NOT lazy) and carry a referrer policy —
        // lazy-loading + null referrer is what produced error 153 (issue #206).
        #expect(!out.contains("loading=\"lazy\""))
        #expect(out.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        #expect(!out.contains("wiki-blob://"))  // external, not blob
        #expect(!out.contains("wiki://"))  // not a fallback cite link
    }

    @Test func embedNonYouTubeIframeKeepsLazyLoading() {
        // Non-goal guard (issue #206): Vimeo/Spotify/etc. iframes render unchanged —
        // still lazy-loaded, no YouTube-specific attributes.
        let id = PageID(rawValue: "01HTESTVIMEO00000000000000")
        let target = EmbedTarget(kind: .iframe, url: "https://player.vimeo.com/video/76979871")
        let out = WikiLinkMarkdown.linkified(
            "![[source:video]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "video/vimeo", target: target) }
        )
        #expect(out.contains("<iframe"))
        #expect(out.contains("player.vimeo.com/video/76979871"))
        #expect(out.contains("loading=\"lazy\""))
    }

    @Test func embedDirectRemoteAudioTargetRendersNativeAudio() {
        let id = PageID(rawValue: "01HTESTMP3000000000000000B")
        let target = EmbedTarget(kind: .audio, url: "https://radio.example.com/live.mp3")
        let out = WikiLinkMarkdown.linkified(
            "![[source:stream]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "audio/mpeg", target: target) }
        )
        #expect(out.contains("<audio"))
        #expect(out.contains("radio.example.com/live.mp3"))
        #expect(out.contains("controls"))
        #expect(!out.contains("wiki-blob://"))
        #expect(!out.contains("wiki://"))
    }

    @Test func embedDirectRemoteVideoTargetRendersNativeVideo() {
        let id = PageID(rawValue: "01HTESTMP4000000000000000C")
        let target = EmbedTarget(kind: .video, url: "https://example.com/clip.mp4")
        let out = WikiLinkMarkdown.linkified(
            "![[source:clip]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "video/mp4", target: target) }
        )
        #expect(out.contains("<video"))
        #expect(out.contains("example.com/clip.mp4"))
        #expect(out.contains("controls"))
        #expect(!out.contains("wiki-blob://"))
    }

    @Test func embedSyntheticMimeWithoutTargetFallsBackToCiteLink() {
        // AC.4 / R2 regression: a byteless source with a synthetic mime
        // (video/youtube) but NO resolved target must fall back to a cite link —
        // NOT emit a broken <video src="wiki-blob://…"> against empty bytes.
        let id = PageID(rawValue: "01HTESTSYN000000000000000D")
        let out = WikiLinkMarkdown.linkified(
            "![[source:video]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "video/youtube") }
        )
        #expect(out.contains("wiki://source"))  // cite link fallback
        #expect(!out.contains("<video"))
        #expect(!out.contains("wiki-blob://"))
    }

    @Test func embedBytefulStillUsesBlobDispatch() {
        // AC.4 regression: a byteful source (target nil) still emits wiki-blob://.
        let id = PageID(rawValue: "01HTESTBYT000000000000000E")
        let out = WikiLinkMarkdown.linkified(
            "![[source:pic.png]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "image/png") }
        )
        #expect(out.contains("<img"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
    }

    @Test func pageEmbedPrefixConsumedAndRendersAsLink() {
        // `![[Page]]` is not a valid embed; the `!` is consumed so it doesn't
        // form a CommonMark image, and the link renders normally.
        let out = WikiLinkMarkdown.linkified("![[Home]]", isResolved: { _, _ in true })
        #expect(out.contains("[Home](wiki://page?title=Home)"))
        #expect(!out.contains("!"))
    }

    @Test func embedInSentenceDoesNotConsumePrecedingText() {
        let id = PageID(rawValue: "01HTESTIMG00000000000000006")
        let out = WikiLinkMarkdown.linkified(
            "Here is ![[source:img.png]] inline.",
            isResolved: { _, _ in true },
            embedInfo: { _ in WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "image/png") }
        )
        #expect(out.hasPrefix("Here is "))
        #expect(out.hasSuffix(" inline."))
        #expect(out.contains("<img"))
    }

    @Test func escapedBangIsNotEmbedAndStaysLiteral() {
        // `\![[source:X]]` — the `\!` stays as literal text, and the link is a
        // normal cite link (the `!` is NOT consumed for non-embeds).
        let out = WikiLinkMarkdown.linkified(
            "\\![[source:X]]",
            isResolved: { _, _ in true }
        )
        #expect(out.contains("wiki://source?title=X"))
        #expect(!out.contains("<img"))
    }

    // MARK: - chat: link rendering

    @Test func resolvedChatLinkUsesChatHost() {
        let out = WikiLinkMarkdown.linkified("[[chat:My Conversation]]") { _, _ in true }
        #expect(out == "[My Conversation](wiki://chat?title=My%20Conversation)")
    }

    @Test func unresolvedChatLinkUsesMissingHost() {
        let out = WikiLinkMarkdown.linkified("[[chat:Ghost]]") { _, _ in false }
        #expect(out == "[Ghost](wiki://missing?title=Ghost)")
    }

    @Test func chatLinkWithAliasPreservesDisplay() {
        let out = WikiLinkMarkdown.linkified("[[chat:My Conversation|the chat]]") { _, _ in true }
        #expect(out.contains("the chat"))
        #expect(out.contains("wiki://chat?title=My%20Conversation"))
    }

    @Test func resolvedKindReturnsChatForChatHost() {
        let url = URL(string: "wiki://chat?title=X")!
        #expect(WikiLinkMarkdown.resolvedKind(from: url) == .chat)
    }

    @Test func targetFromAcceptsChatHost() {
        let url = URL(string: "wiki://chat?title=My%20Conversation")!
        #expect(WikiLinkMarkdown.target(from: url) == "My Conversation")
    }

    @Test func isResolvedURLTrueForChatHost() {
        #expect(WikiLinkMarkdown.isResolvedURL(URL(string: "wiki://chat?title=X")!))
    }

    @Test func chatLinkWithFragmentRendersFragmentInURL() {
        let out = WikiLinkMarkdown.linkified("[[chat:Conv#Section]]") { name, kind in
            name == "Conv" && kind == .chat
        }
        #expect(out == "[Conv](wiki://chat?title=Conv#Section)")
    }

    @Test func emptyChatPrefixRendersAsLiteral() {
        // [[chat:]] should stay verbatim, not become a link.
        let out = WikiLinkMarkdown.linkified("before [[chat:]] after") { _, _ in true }
        #expect(out.contains("[[chat:]]"))
        #expect(!out.contains("wiki://"))
    }

    @Test func chatEmbedPrefixConsumedAndRendersAsLink() {
        // `![[chat:…]]` is not a valid embed — the `!` is consumed and it
        // renders as a normal chat link (consistent with `![[Page]]`).
        let out = WikiLinkMarkdown.linkified("![[chat:Conv]]") { _, _ in true }
        #expect(out.contains("wiki://chat?title=Conv"))
        #expect(!out.contains("<img"))
        #expect(!out.contains("!"))
    }

    // Pull the URL substring out of a single `[text](url)` for assertions.
    private func extractURL(_ markdownLink: String) -> String {
        guard let open = markdownLink.lastIndex(of: "("),
              let close = markdownLink.lastIndex(of: ")") else { return "" }
        return String(markdownLink[markdownLink.index(after: open)..<close])
    }
}
