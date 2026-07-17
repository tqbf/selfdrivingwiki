import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the `[[wiki-link]]` → relative-Markdown-link rewriter used by
/// the `by-title` / `by-name` FileProvider projections. No store, no view: the
/// namespace resolution + baseDir are injected, exactly as `Projection` supplies.
struct RelativeLinkRewriterTests {

    // Canonical ULIDs for the fixture rows (26-char Crockford base32, uppercase).
    private static let homeID   = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private static let alphaID  = "01BBBBBBBBBBBBBBBBBBBBBBBB"
    private static let srcID     = "01CCCCCCCCCCCCCCCCCCCCCCCC"
    private static let chatID    = "01DDDDDDDDDDDDDDDDDDDDDDDD"

    private typealias Target = RelativeLinkRewriter.Target

    private static let pages: [String: Target] = [
        "Home":  Target(path: ["pages", "by-title", "Home--01AAAAAA.md"], title: "Home"),
        "Alpha": Target(path: ["pages", "by-title", "Alpha--01BBBBBB.md"], title: "Alpha"),
        "C# Guide": Target(path: ["pages", "by-title", "C# Guide--01AAAAAA.md"], title: "C# Guide"),
    ]
    private static let pagesByID: [String: Target] = [
        homeID.uppercased():  pages["Home"]!,
        alphaID.uppercased(): pages["Alpha"]!,
    ]
    private static let sources: [String: Target] = [
        "Teleportation.pdf": Target(path: ["sources", "by-name", "Teleportation--01CCCCCC.md"],
                                    title: "Teleportation.pdf"),
    ]
    private static let sourcesByID: [String: Target] = [
        srcID.uppercased(): sources["Teleportation.pdf"]!,
    ]
    private static let chats: [String: Target] = [
        "My Chat": Target(path: ["chats", "by-name", "My Chat--01DDDDDD.md"], title: "My Chat"),
    ]
    private static let chatsByID: [String: Target] = [
        chatID.uppercased(): chats["My Chat"]!,
    ]

    /// A resolver rooted at `baseDir` (default: the page by-title view).
    private func resolver(baseDir: [String] = ["pages", "by-title"]) -> RelativeLinkRewriter.Resolver {
        RelativeLinkRewriter.Resolver(
            baseDir: baseDir,
            page:   { t, isID in isID ? Self.pagesByID[t.uppercased()]   : Self.pages[t] },
            source: { t, isID in isID ? Self.sourcesByID[t.uppercased()] : Self.sources[t] },
            chat:   { t, isID in isID ? Self.chatsByID[t.uppercased()]   : Self.chats[t] }
        )
    }

    /// Convenience: rewrite from the page view.
    private func rewrite(_ body: String, baseDir: [String] = ["pages", "by-title"]) -> String {
        RelativeLinkRewriter.rewrite(body, resolver: resolver(baseDir: baseDir))
    }

    // MARK: - Page links (name-based)

    @Test func simplePageLinkBecomesSiblingLink() {
        #expect(rewrite("See [[Home]] here.") == "See [Home](Home--01AAAAAA.md) here.")
    }

    @Test func aliasedLinkUsesAliasTextAndTargetFilename() {
        #expect(rewrite("Go to [[Home|start page]].") == "Go to [start page](Home--01AAAAAA.md).")
    }

    @Test func multipleLinksAreEachRewritten() {
        #expect(rewrite("[[Home]] and [[Alpha]].")
            == "[Home](Home--01AAAAAA.md) and [Alpha](Alpha--01BBBBBB.md).")
    }

    // MARK: - Canonical ULID page links (Phase 5 form)

    @Test func canonicalULIDPageLinkResolvesByIDAndUsesAlias() {
        #expect(rewrite("A [[page:\(Self.homeID)|Geoffrey Litt]] essay.")
            == "A [Geoffrey Litt](Home--01AAAAAA.md) essay.")
    }

    @Test func canonicalULIDPageLinkWithoutAliasUsesCurrentTitle() {
        #expect(rewrite("See [[page:\(Self.alphaID)]].") == "See [Alpha](Alpha--01BBBBBB.md).")
    }

    @Test func canonicalULIDPageLinkPreservesHeadingFragment() {
        #expect(rewrite("[[page:\(Self.homeID)#Intro|home intro]]")
            == "[home intro](Home--01AAAAAA.md#Intro)")
    }

    @Test func canonicalULIDForDeletedPageStaysVerbatim() {
        let missing = "01ZZZZZZZZZZZZZZZZZZZZZZZZ"
        #expect(rewrite("[[page:\(missing)|Gone]]") == "[[page:\(missing)|Gone]]")
    }

    @Test func lowercaseULIDIsTreatedAsNameAndStaysVerbatim() {
        // ULID.allowedCharacters is uppercase-only by design: a lowercase ULID
        // is NOT canonical, resolves by name → no match → left verbatim.
        let lower = Self.homeID.lowercased()
        #expect(rewrite("[[page:\(lower)|Home]]") == "[[page:\(lower)|Home]]")
    }

    // MARK: - Source links → sources/by-name (cross-namespace)

    @Test func canonicalSourceLinkResolvesToRelativePath() {
        // From pages/by-title, a source cite climbs out to sources/by-name.
        let out = rewrite("Cite [[source:\(Self.srcID)|the essay]].")
        #expect(out == "Cite [the essay](../../sources/by-name/Teleportation--01CCCCCC.md).")
    }

    @Test func sourceQuoteFragmentIsDropped() {
        // A `#"quote"` cite fragment isn't a resolvable anchor — drop it.
        let out = rewrite("[[source:\(Self.srcID)#\"What if we invented teleportation?\"|cite]]")
        #expect(out == "[cite](../../sources/by-name/Teleportation--01CCCCCC.md)")
    }

    @Test func nameBasedSourceLinkResolves() {
        let out = rewrite("[[source:Teleportation.pdf]]")
        #expect(out == "[Teleportation.pdf](../../sources/by-name/Teleportation--01CCCCCC.md)")
    }

    @Test func unknownSourceLinkStaysVerbatim() {
        #expect(rewrite("[[source:missing.pdf]]") == "[[source:missing.pdf]]")
    }

    @Test func sourceLinkWithDashMismatchResolvesViaLooseKey() {
        // The agent cited "Self-Driving Wiki User Guide" but the source is
        // named "Self-Driving Wiki — User Guide" (em dash). The resolver's
        // loose-key fallback should still resolve it. This mirrors the
        // production LinkMaps.resolver which falls back to looseMatchKey.
        let storedName = "Self-Driving Wiki \u{2014} User Guide"
        var looseSources: [String: Target] = [:]
        var seen = Set<String>()
        for (name, target) in Self.sources {
            let key = WikiNameRules.looseMatchKey(name)
            if !seen.insert(key).inserted { looseSources.removeValue(forKey: key) }
            else { looseSources[key] = target }
        }
        let storedTarget = Target(path: ["sources", "by-name", "Self-Driving Wiki \u{2014} User Guide--01CCCCCC.md"],
                                  title: storedName)
        var sources = Self.sources
        sources[storedName] = storedTarget
        looseSources[WikiNameRules.looseMatchKey(storedName)] = storedTarget

        let resolver = RelativeLinkRewriter.Resolver(
            baseDir: ["pages", "by-title"],
            page:   { t, isID in isID ? Self.pagesByID[t.uppercased()] : Self.pages[t] },
            source: { t, isID in
                if isID { return Self.sourcesByID[t.uppercased()] }
                return sources[t] ?? looseSources[WikiNameRules.looseMatchKey(t)]
            },
            chat:   { t, isID in isID ? Self.chatsByID[t.uppercased()] : Self.chats[t] }
        )
        let out = RelativeLinkRewriter.rewrite(
            "[[source:Self-Driving Wiki User Guide#Launch the app]]",
            resolver: resolver)
        #expect(out.contains("../../sources/by-name/"))
        #expect(out.contains("--01CCCCCC.md"))
        #expect(!out.contains("[[source:"))
    }

    // MARK: - Chat links → chats/by-name (cross-namespace)

    @Test func canonicalChatLinkResolvesToRelativePath() {
        // The space in "My Chat" is percent-encoded in the PATH; the display
        // text keeps the literal space.
        let out = rewrite("See [[chat:\(Self.chatID)|our chat]].")
        #expect(out == "See [our chat](../../chats/by-name/My%20Chat--01DDDDDD.md).")
    }

    @Test func nameBasedChatLinkResolves() {
        let out = rewrite("[[chat:My Chat]]")
        #expect(out == "[My Chat](../../chats/by-name/My%20Chat--01DDDDDD.md)")
    }

    @Test func unknownChatLinkStaysVerbatim() {
        #expect(rewrite("[[chat:Nope]]") == "[[chat:Nope]]")
    }

    // MARK: - baseDir sensitivity (same doc kind → sibling; cross-kind → climb)

    @Test func sourceViewLinkingToAnotherSourceIsSibling() {
        // A source markdown sibling links to another source in the same dir.
        let out = rewrite("[[source:\(Self.srcID)|self]]", baseDir: ["sources", "by-name"])
        #expect(out == "[self](Teleportation--01CCCCCC.md)")
    }

    @Test func sourceViewLinkingToPageClimbsOut() {
        let out = rewrite("[[Home]]", baseDir: ["sources", "by-name"])
        #expect(out == "[Home](../../pages/by-title/Home--01AAAAAA.md)")
    }

    @Test func chatViewLinkingToPageClimbsOut() {
        let out = rewrite("[[page:\(Self.homeID)|Home]]", baseDir: ["chats", "by-name"])
        #expect(out == "[Home](../../pages/by-title/Home--01AAAAAA.md)")
    }

    // MARK: - Hash-in-title disambiguation

    @Test func hashInTitleIsDisambiguatedCorrectly() {
        // "C# Guide" is a real page; "C" is not.
        #expect(rewrite("See [[C# Guide]].") == "See [C# Guide](C%23%20Guide--01AAAAAA.md).")
    }

    // MARK: - Anchors (page headings)

    @Test func anchorIsPreservedAfterFilename() {
        #expect(rewrite("See [[Home#Introduction]].")
            == "See [Home](Home--01AAAAAA.md#Introduction).")
    }

    @Test func aliasedAnchorLinkUsesAliasAndPreservesFragment() {
        #expect(rewrite("[[Home#Intro|intro]]") == "[intro](Home--01AAAAAA.md#Intro)")
    }

    // MARK: - Unresolvable / non-link forms stay verbatim

    @Test func unknownPageLinkStaysVerbatim() {
        #expect(rewrite("[[Deleted Page]]") == "[[Deleted Page]]")
    }

    @Test func embedStaysVerbatim() {
        #expect(rewrite("![[source:image.png]]") == "![[source:image.png]]")
    }

    @Test func canonicalSourceEmbedStaysVerbatim() {
        let body = "![[source:\(Self.srcID)]]"
        #expect(rewrite(body) == body)
    }

    @Test func linkInsideCodeSpanIsLeftVerbatim() {
        #expect(rewrite("Use `[[Home]]` in code.") == "Use `[[Home]]` in code.")
    }

    @Test func linkInsideFencedBlockIsLeftVerbatim() {
        let body = "```\n[[Home]]\n```"
        #expect(rewrite(body) == body)
    }

    @Test func samePageAnchorStaysVerbatim() {
        #expect(rewrite("Jump to [[#Introduction]].") == "Jump to [[#Introduction]].")
    }

    // MARK: - Percent-encoding

    @Test func filenameWithSpacesIsPercentEncodedPerComponent() {
        // Spaces in the filename → %20; the `/` path separators are NOT encoded.
        let out = rewrite("[[chat:My Chat]]")
        #expect(out == "[My Chat](../../chats/by-name/My%20Chat--01DDDDDD.md)")
        #expect(!out.contains("%2F"))   // separators intact
    }

    // MARK: - Passthrough

    @Test func bodyWithNoLinksIsReturnedUnchanged() {
        let body = "Just plain text, no wikilinks."
        #expect(rewrite(body) == body)
    }

    @Test func yamlFrontmatterIsNotModified() {
        let body = """
        ---
        title: "Home"
        date: 2026-07-11
        ---

        # Home

        See [[Alpha]].
        """
        let out = rewrite(body)
        #expect(out.hasPrefix("---\ntitle: \"Home\"\ndate: 2026-07-11\n---"))
        #expect(out.contains("[Alpha](Alpha--01BBBBBB.md)"))
    }

    // MARK: - relativePath unit

    @Test func relativePathSameDirIsBareFilename() {
        let p = RelativeLinkRewriter.relativePath(
            from: ["pages", "by-title"], to: ["pages", "by-title", "Home--01AA.md"])
        #expect(p == "Home--01AA.md")
    }

    @Test func relativePathCrossSubtreeClimbs() {
        let p = RelativeLinkRewriter.relativePath(
            from: ["pages", "by-title"], to: ["sources", "by-name", "x.md"])
        #expect(p == "../../sources/by-name/x.md")
    }
}
