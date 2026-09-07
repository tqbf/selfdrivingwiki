#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

struct DocumentEmbedResolverTests {
    private let pageID = PageID(rawValue: "01J00000000000000000000001")
    private let sourceID = SourceID(rawValue: "01J00000000000000000000002")

    @Test func syntaxSelectsInlineAndDisclosureRoles() throws {
        let embed = try sourceEmbed("![[source:image.png]]")
        #expect(DocumentEmbedSyntax.wikiSourceMedia(embed).requiredEmbeddingRole == .inlineContent)
        #expect(DocumentEmbedSyntax.markdownImage(sourceRange: nil, source: "image.png", altText: "").requiredEmbeddingRole == .inlineContent)

        let identity = MarkdownDocumentIdentity(
            pageID: pageID,
            pageVersionID: PageVersionID(rawValue: "01J00000000000000000000003"))
        let block = try MarkdownFencedBlock(
            documentIdentity: identity,
            parserOrdinal: 0,
            rawInfoString: "mermaid",
            bytes: Data("graph TD; A-->B".utf8))
        #expect(DocumentEmbedSyntax.richFence(block).requiredEmbeddingRole == .disclosureRow)
    }

    @Test func pageWinsBareEmbedCollision() throws {
        let embed = try sourceEmbed("![[Shared]]")
        let source = sourceResolution(mime: "image/png")
        let resolver = DocumentEmbedResolver(inputs: .init(
            pageIDByName: ["shared": pageID],
            sourceByName: ["shared": source],
            pageTitlesByID: [pageID: "Shared"],
            sourceNamesByID: [sourceID: "Shared"]))

        guard case .transclusion(.page(let resolvedID), _, _, _) = resolver.resolveWikiEmbed(embed) else {
            Issue.record("Expected page transclusion")
            return
        }
        #expect(resolvedID == pageID)
    }

    @Test(arguments: [
        ("image/png", DocumentMediaKind.image),
        ("audio/mpeg", DocumentMediaKind.audio),
        ("video/mp4", DocumentMediaKind.video),
        (MimeType.pdf, DocumentMediaKind.pdf),
    ])
    func inlineMediaKindsShareResolvedContract(mime: String, expected: DocumentMediaKind) throws {
        let embed = try sourceEmbed("![[source:Media]]")
        let source = sourceResolution(mime: mime)
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["media": source],
            sourceNamesByID: [sourceID: "Media"]))

        guard case .inlineMedia(_, let kind, _, .blob(let resolvedID), _) = resolver.resolveWikiEmbed(embed) else {
            Issue.record("Expected inline media")
            return
        }
        #expect(kind == expected)
        #expect(resolvedID == sourceID)
    }

    @Test func mermaidSourceResolvesThroughTheGenericRendererArmWhenClaimed() throws {
        // A .mmd source with a matching inline package plan resolves through
        // the generic source-renderer arm — the same path as any other
        // renderer-package source, with no host format branch.
        let embed = try sourceEmbed("![[source:diagram.mmd]]")
        let bytes = Data("graph TD; A-->B".utf8)
        let source = DocumentSourceResolution(
            sourceID: sourceID,
            version: .source(SourceVersionID(rawValue: "01J00000000000000000000004")),
            displayName: "diagram.mmd",
            mimeType: "text/mermaid",
            bytes: nil,
            externalTarget: nil)
        let pinnedSource = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01J00000000000000000000004"),
            mimeType: try .init(validating: "text/mermaid"),
            fileExtension: "mmd",
            bytes: bytes)
        let plan = RendererEmbedPlan(
            placeholderID: "diagram-plan",
            embeddingRole: .inlineContent,
            rendererReference: RendererReference(
                packageID: PackageFenceTestSupport.installedPackageID,
                version: PackageFenceTestSupport.installedPackageVersion,
                registrationID: PackageFenceTestSupport.installedRegistrationID),
            input: .source(pinnedSource),
            semanticContent: "diagram",
            activationMetadata: .init(
                controlLabel: "Open",
                accessibilityLabel: "Open inline source renderer",
                summary: "Open the source in the renderer pane."))
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["diagram.mmd": source],
            sourceNamesByID: [sourceID: "diagram.mmd"],
            sourceRendererCandidates: [sourceID: plan]))

        guard case .renderer(let syntax, .inlineContent, let resolvedPlan, _) = resolver.resolveWikiEmbed(embed) else {
            Issue.record("Expected a claimed diagram source to resolve through the generic renderer arm")
            return
        }
        #expect(syntax.requiredEmbeddingRole == .inlineContent)
        #expect(resolvedPlan.rendererReference == plan.rendererReference)
        #expect(resolvedPlan.input == .source(pinnedSource))
    }

    @Test func mermaidSourceFallsBackToTransclusionWhenNoPackageClaimsIt() throws {
        // The no-package leg: nothing claims the format, so the embed stays a
        // readable tagged transclusion of the source bytes.
        let embed = try sourceEmbed("![[source:diagram.mmd]]")
        let source = DocumentSourceResolution(
            sourceID: sourceID,
            version: .source(SourceVersionID(rawValue: "01J00000000000000000000004")),
            displayName: "diagram.mmd",
            mimeType: "text/mermaid",
            bytes: nil,
            externalTarget: nil)
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["diagram.mmd": source],
            sourceNamesByID: [sourceID: "diagram.mmd"]))

        guard case .transclusion(.source(let resolvedID), _, _, _) = resolver.resolveWikiEmbed(embed) else {
            Issue.record("Expected an unclaimed diagram source to resolve as transclusion")
            return
        }
        #expect(resolvedID == sourceID)
    }

    @Test func nonMediaSourceUsesTaggedTransclusion() throws {
        let embed = try sourceEmbed("![[source:Notes#Section]]")
        let source = sourceResolution(mime: "text/markdown")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["notes": source],
            sourceNamesByID: [sourceID: "Notes"]))

        guard case .transclusion(.source(let resolvedID), _, let fragment, _) = resolver.resolveWikiEmbed(embed) else {
            Issue.record("Expected source transclusion")
            return
        }
        #expect(resolvedID == sourceID)
        #expect(fragment == "Section")
    }

    @Test func sourceLinksKeepLegacyExistenceTiersWithoutBroadeningEmbeds() throws {
        let exactLink = try sourceLink("[[source:Report]]")
        let looseLink = try sourceLink("[[source:My-Paper]]")
        let legacyLiteral = "Paper.pdf–\(sourceID.rawValue).md"
        let legacyLink = try sourceLink("[[source:\(legacyLiteral)]]")
        let ambiguousEmbed = try sourceEmbed("![[source:Report]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: [:],
            sourceLinkNames: ["report"],
            uniqueSourceLooseKeys: [WikiNameRules.looseMatchKey("My Paper")],
            sourceNamesByID: [sourceID: "Paper.pdf"]))

        #expect(resolver.resolveWikiLink(exactLink).isResolved)
        #expect(resolver.resolveWikiLink(looseLink).isResolved)
        #expect(resolver.resolveWikiLink(legacyLink).isResolved)
        guard case .missing(.source(let literal), _) = resolver.resolveWikiEmbed(ambiguousEmbed) else {
            Issue.record("Ambiguous source names must not authorize embeds")
            return
        }
        #expect(literal == "Report")
    }

    @Test func missingSourceLinkRemainsUnresolved() throws {
        let link = try sourceLink("[[source:Missing]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceLinkNames: ["known"],
            uniqueSourceLooseKeys: [WikiNameRules.looseMatchKey("Other")]))

        #expect(!resolver.resolveWikiLink(link).isResolved)
    }

    // MARK: - Pipe inside the NAME (issue #1225 — typed render path)
    //
    // The production reader renders through this resolver, not through
    // `WikiLinkMarkdown.linkified`. A name-authored link to a pipe-containing
    // title splits at the unquoted `|` (span scan), so the truncated literal
    // used to miss every existence tier and the link rendered as inert
    // `wiki://missing` with only the post-pipe alias fragment as its label.
    // The reconstruction fallback (mirror of #619's seams) heals exactly that
    // case — and only that case.

    private static let pipeTitle = "What is Malleable Software Now | Bryan Min (02-27-2026)"

    @Test func pipeNameSourceLinkResolvesAndDisplaysFullName() throws {
        let link = try sourceLink("[[source:\(Self.pipeTitle)]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceLinkNames: [Self.pipeTitle.lowercased()]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.namespace == .source)
        // AC: the label AND the navigation title are the complete title.
        #expect(resolved.displayText == Self.pipeTitle)
        #expect(resolved.title == Self.pipeTitle)
        #expect(resolved.fragment == nil)
    }

    @Test func pipeNameSourceLinkWithQuoteFragmentResolves() throws {
        // The exact stored shape (Malleable Software wiki, source
        // 01KZ5FS7A76RDDXFQFC5DKJ1SJ): the `#"quote"` anchor rides in the
        // alias slice; reconstruction peels it back off the full name.
        let link = try sourceLink(
            "[[source:\(Self.pipeTitle)#\"a quoted passage\"]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceLinkNames: [Self.pipeTitle.lowercased()]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.displayText == Self.pipeTitle)
        #expect(resolved.fragment == "\"a quoted passage\"")
    }

    @Test func unspacedPipeNameSourceLinkResolves() throws {
        // The unspaced `A|B` spelling is the second reconstruction candidate.
        let link = try sourceLink("[[source:Flex Tier|Neuralwatt Cloud]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceLinkNames: ["flex tier|neuralwatt cloud"]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.displayText == "Flex Tier|Neuralwatt Cloud")
    }

    @Test func pipeNameLooseKeySourceLinkResolves() throws {
        // The lenient (unique loose key) tier also applies to the
        // reconstructed whole name, mirroring the truncated-literal tiers.
        let link = try sourceLink("[[source:My-Paper | Extended Edition]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            uniqueSourceLooseKeys: [
                WikiNameRules.looseMatchKey("My-Paper | Extended Edition (2026)"),
            ]))

        #expect(resolver.resolveWikiLink(link).isResolved)
    }

    @Test func pipeNamePageLinkResolves() throws {
        let link = try wikiLink(
            "[[But what is cross-entropy? | Compression is Intelligence Part 2]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            pageIDByName: [
                "but what is cross-entropy? | compression is intelligence part 2": pageID,
            ]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.namespace == .page)
        #expect(resolved.displayText
                == "But what is cross-entropy? | Compression is Intelligence Part 2")
    }

    @Test func pipeNameChatLinkResolves() throws {
        let link = try wikiLink("[[chat:Standup - 2026-01-15 | Project Alpha]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            chatIDByName: [
                "standup - 2026-01-15 | project alpha":
                    ChatID(rawValue: "01J00000000000000000000009"),
            ]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.namespace == .chat)
        #expect(resolved.displayText == "Standup - 2026-01-15 | Project Alpha")
    }

    @Test func canonicalULIDSourceLinkDisplaysCurrentPipeTitle() throws {
        // AC (canonical ULID-backed): no alias at all — the live store name
        // (pipe included) is the label via the id→name map.
        let link = try sourceLink("[[source:\(sourceID.rawValue)]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceNamesByID: [sourceID: Self.pipeTitle]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.canonicalID == sourceID.rawValue)
        #expect(resolved.displayText == Self.pipeTitle)
    }

    @Test func canonicalULIDSourceLinkHealsStalePipeAlias() throws {
        // AC (canonical ULID-backed): a stale pre-#619 alias that lost the
        // head of the title self-heals to the current store name at render.
        let link = try sourceLink(
            "[[source:\(sourceID.rawValue)|Bryan Min (02-27-2026)]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceNamesByID: [sourceID: Self.pipeTitle]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.displayText == Self.pipeTitle)
    }

    @Test func canonicalULIDSourceLinkWithPipeInAliasKeepsWholeAlias() throws {
        // The canonical auto-alias form `[[source:<ULID>|<full title>]]`: the
        // first pipe (after the ULID) is the separator, and the title's own
        // pipe stays inside the alias — no reconstruction needed or wanted.
        let link = try sourceLink("[[source:\(sourceID.rawValue)|\(Self.pipeTitle)]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceNamesByID: [sourceID: Self.pipeTitle]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.displayText == Self.pipeTitle)
    }

    @Test func explicitAliasWinsWhenLeftHandResolves() throws {
        // AC: an explicit target|alias keeps the alias when the left-hand
        // target resolves on its own — reconstruction never runs.
        let link = try sourceLink("[[source:Known|Bryan Min (02-27-2026)]]")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceLinkNames: ["known"]))

        let resolved = resolver.resolveWikiLink(link)
        #expect(resolved.isResolved)
        #expect(resolved.displayText == "Bryan Min (02-27-2026)")
    }

    @Test func pipeNameUnresolvableFallsBackToAliasDisplay() throws {
        // AC: when neither the truncated target nor any reconstruction
        // resolves, the link stays inert (`wiki://missing` upstream) and
        // displays the alias — the pre-#619 behavior is the fallback.
        let link = try sourceLink("[[source:Ghost | Pipeline]]")
        let resolver = DocumentEmbedResolver(inputs: .init())

        let resolved = resolver.resolveWikiLink(link)
        #expect(!resolved.isResolved)
        #expect(resolved.displayText == "Pipeline")
        #expect(resolved.title == "Ghost")
    }

    @Test func repeatedImageRendererCandidatesUseUniqueActionPlansWithoutDynamicHosts() throws {
        let markdown = "![[source:image.png|First]] and ![[source:image.png|Second]]"
        let prepared = ReaderMarkdown.preparedDocument(markdown)
        let source = sourceResolution(mime: "image/png")
        let plan = RendererEmbedPlan(
            placeholderID: "source-plan",
            embeddingRole: .inlineContent,
            rendererReference: try reference(),
            input: nil,
            semanticContent: "source",
            activationMetadata: .init(
                controlLabel: "Open",
                accessibilityLabel: "Open source",
                summary: "Source renderer"))
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["image.png": source],
            sourceNamesByID: [sourceID: "image.png"],
            sourceRendererCandidates: [sourceID: plan]))
        let projection = resolver.projection(for: prepared)
        let embeds = prepared.wikiSyntax.compactMap { node -> ResolvedDocumentEmbed? in
            guard case .embed(let embed) = node else { return nil }
            return projection.wikiEmbed(at: embed.sourceRange)
        }
        let actionPlanIDs = embeds.compactMap { embed -> String? in
            guard case .renderer(_, let role, let plan, _) = embed,
                  role == .inlineContent else { return nil }
            return plan.placeholderID
        }

        #expect(actionPlanIDs.count == 2)
        #expect(Set(actionPlanIDs).count == 2)

        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: .disabled)
        #expect(html.components(separatedBy: "<img src=\"wiki-blob://source/\(sourceID.rawValue)\"").count - 1 == 2)
        #expect(html.components(separatedBy: "class=\"sdw-inline-renderer\"").count - 1 == 2)
        #expect(!html.contains("data-renderer-admitted=\"true\""))
        #expect(!html.contains("id=\"sdw-inline-renderer-"))
    }

    @Test func installedRendererPlanUsesGenericInlineAttachmentFallback() throws {
        let bytes = Data(##"{"type":"excalidraw","version":2,"elements":[]}"##.utf8)
        let source = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01J00000000000000000000005"),
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        let plan = RendererEmbedPlan(
            placeholderID: "installed-renderer",
            embeddingRole: .inlineContent,
            rendererReference: RendererReference(
                packageID: PackageFenceTestSupport.installedPackageID,
                version: PackageFenceTestSupport.installedPackageVersion,
                registrationID: PackageFenceTestSupport.installedRegistrationID),
            input: .source(source),
            semanticContent: "drawing",
            activationMetadata: .init(
                controlLabel: "Open",
                accessibilityLabel: "Open inline source renderer",
                summary: "Open the source in the renderer pane."))

        let resolved = DocumentEmbedResolver(inputs: .init()).resolveMarkdownImage(
            source: "drawing.json",
            altText: "Installed drawing",
            target: .renderer(rendererReference: plan.rendererReference, source: source))
        guard case .renderer(_, .inlineContent, let resolvedPlan, .media(let label, .blob(let resolvedSourceID))) = resolved else {
            Issue.record("Expected a generic renderer attachment with a readable fallback")
            return
        }
        #expect(resolvedPlan.rendererReference == plan.rendererReference)
        #expect(label == "Installed drawing")
        #expect(resolvedSourceID == sourceID)
    }

    @Test func rendererFallbackKeepsReadableSourceWhenPackageOutputIsUnavailable() throws {
        let unsupportedBytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"type":"image","x":0,"y":0,"width":10,"height":10,"angle":0,"strokeColor":"#000000","backgroundColor":"transparent","strokeWidth":1,"opacity":100,"roundness":null,"isDeleted":false}]}"##.utf8)
        let source = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01J00000000000000000000006"),
            mimeType: try .init(validating: "application/json"),
            bytes: unsupportedBytes)
        let rendererReference = RendererReference(
            packageID: PackageFenceTestSupport.installedPackageID,
            version: PackageFenceTestSupport.installedPackageVersion,
            registrationID: PackageFenceTestSupport.installedRegistrationID)
        let resolved = DocumentEmbedResolver(inputs: .init()).resolveMarkdownImage(
            source: "unsupported.json",
            altText: "Unsupported drawing",
            target: .renderer(rendererReference: rendererReference, source: source))
        guard case .renderer(_, .inlineContent, let fallbackPlan, .media(let label, .blob(let fallbackSourceID))) = resolved else {
            Issue.record("An unavailable package must keep a readable source fallback")
            return
        }
        #expect(fallbackPlan.rendererReference == rendererReference)
        #expect(fallbackSourceID == sourceID)
        #expect(label == "Unsupported drawing")
    }

    @Test func rendererMustKeepInlineRole() throws {
        let embed = try sourceEmbed("![[source:image.png]]")
        let source = sourceResolution(mime: "image/png")
        let rowPlan = RendererEmbedPlan(
            placeholderID: "row-only",
            embeddingRole: .disclosureRow,
            rendererReference: try reference(),
            semanticContent: "row")
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["image.png": source],
            sourceNamesByID: [sourceID: "image.png"],
            sourceRendererCandidates: [sourceID: rowPlan]))

        guard case .inlineMedia = resolver.resolveWikiEmbed(embed) else {
            Issue.record("A disclosure-only renderer must not claim inline syntax")
            return
        }
    }

    private func sourceEmbed(_ markdown: String) throws -> WikiMarkdownSyntaxNode.Embed {
        let node = try #require(WikiLinkParser.syntaxNodes(in: markdown).first)
        guard case .embed(let embed) = node else {
            throw TestError.expectedEmbed
        }
        return embed
    }

    private func sourceLink(_ markdown: String) throws -> WikiMarkdownSyntaxNode.Link {
        let node = try #require(WikiLinkParser.syntaxNodes(in: markdown).first)
        guard case .link(let link) = node else {
            throw TestError.expectedLink
        }
        return link
    }

    /// A link node of any namespace (page/chat links included) — `sourceLink`
    /// asserts nothing about namespace, but the name reads better for pages.
    private func wikiLink(_ markdown: String) throws -> WikiMarkdownSyntaxNode.Link {
        try sourceLink(markdown)
    }

    private func sourceResolution(mime: String) -> DocumentSourceResolution {
        DocumentSourceResolution(
            sourceID: sourceID,
            version: .source(SourceVersionID(rawValue: "01J00000000000000000000004")),
            displayName: "Media",
            mimeType: mime,
            bytes: Data("bytes".utf8),
            externalTarget: nil)
    }

    private func reference() throws -> RendererReference {
        RendererReference(
            packageID: try RendererPackageID(validating: "org.example.renderer"),
            version: try RendererPackageVersion(validating: "1.0.0"),
            registrationID: try RendererRegistrationID(validating: "renderer"))
    }

    private enum TestError: Error { case expectedEmbed, expectedLink }
}
#endif
