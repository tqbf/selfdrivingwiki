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

    @Test func mermaidSourceIsInlineWithoutRendererRolePromotion() throws {
        let embed = try sourceEmbed("![[source:diagram.mmd]]")
        let source = DocumentSourceResolution(
            sourceID: sourceID,
            version: .source(SourceVersionID(rawValue: "01J00000000000000000000004")),
            displayName: "diagram.mmd",
            mimeType: "text/mermaid",
            bytes: Data("graph TD; A-->B".utf8),
            externalTarget: nil,
            isMermaidSource: true)
        let resolver = DocumentEmbedResolver(inputs: .init(
            sourceByName: ["diagram.mmd": source],
            sourceNamesByID: [sourceID: "diagram.mmd"]))

        guard case .inlineMedia(let syntax, .mermaidSource, _, .authored(let text), .code(let language, let fallback)) = resolver.resolveWikiEmbed(embed) else {
            Issue.record("Expected inline Mermaid source")
            return
        }
        #expect(syntax.requiredEmbeddingRole == .inlineContent)
        #expect(text == "graph TD; A-->B")
        #expect(language == "mermaid")
        #expect(fallback == text)
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

    @Test func repeatedInlineSourceRendererEmbedsUseUniquePlaceholders() throws {
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
        let placeholderIDs = embeds.compactMap { embed -> String? in
            guard case .renderer(_, let role, let plan, _) = embed,
                  role == .inlineContent else { return nil }
            return plan.placeholderID
        }

        #expect(placeholderIDs.count == 2)
        #expect(Set(placeholderIDs).count == 2)
    }

    @Test func bundledExcalidrawProjectsToTypedInertDOMOutput() throws {
        let bytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"type":"rectangle","x":1,"y":2,"width":30,"height":40,"angle":0,"strokeColor":"#112233","backgroundColor":"#ffffff","strokeWidth":2,"opacity":100,"roundness":null,"isDeleted":false}]}"##.utf8)
        let source = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01J00000000000000000000005"),
            mimeType: try .init(validating: "application/json"),
            bytes: bytes)
        let plan = RendererEmbedPlan(
            placeholderID: "excalidraw-dom",
            embeddingRole: .inlineContent,
            rendererReference: .init(
                packageID: BundledRendererPackages.excalidrawPackageID,
                version: BundledRendererPackages.excalidrawVersion,
                registrationID: BundledRendererPackages.excalidrawRegistrationID),
            input: .source(source),
            semanticContent: "drawing")

        guard case .vectorScene(let scene) = DocumentRendererDOMProjector.project(plan) else {
            Issue.record("Expected a typed vector scene")
            return
        }
        #expect(scene.elements.count == 1)
        #expect(scene.bounds.width == 78)
        #expect(scene.bounds.height == 88)
    }

    @Test func excalidrawDOMProjectionFailsClosedForUnsupportedOrWrongRendererInput() throws {
        let unsupportedBytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"type":"image","x":0,"y":0,"width":10,"height":10,"angle":0,"strokeColor":"#000000","backgroundColor":"transparent","strokeWidth":1,"opacity":100,"roundness":null,"isDeleted":false}]}"##.utf8)
        let source = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01J00000000000000000000006"),
            mimeType: try .init(validating: "application/json"),
            bytes: unsupportedBytes)
        let exactPlan = RendererEmbedPlan(
            placeholderID: "unsupported-excalidraw",
            embeddingRole: .inlineContent,
            rendererReference: .init(
                packageID: BundledRendererPackages.excalidrawPackageID,
                version: BundledRendererPackages.excalidrawVersion,
                registrationID: BundledRendererPackages.excalidrawRegistrationID),
            input: .source(source),
            semanticContent: "drawing")
        let wrongPackagePlan = RendererEmbedPlan(
            placeholderID: "lookalike-excalidraw",
            embeddingRole: .inlineContent,
            rendererReference: try reference(),
            input: .source(source),
            semanticContent: "drawing")

        #expect(DocumentRendererDOMProjector.project(exactPlan) == nil)
        #expect(DocumentRendererDOMProjector.project(wrongPackagePlan) == nil)

        let resolved = DocumentEmbedResolver(inputs: .init()).resolveMarkdownImage(
            source: "unsupported.excalidraw",
            altText: "Unsupported drawing",
            target: .renderer(rendererReference: exactPlan.rendererReference, source: source))
        guard case .fallback(.image(let fallbackSource, let altText)) = resolved else {
            Issue.record("Unsupported trusted Excalidraw input must keep the image fallback")
            return
        }
        #expect(fallbackSource == "wiki-blob://source/\(sourceID.rawValue)")
        #expect(altText == "Unsupported drawing")

        let extremeBytes = Data(##"{"type":"excalidraw","version":2,"elements":[{"type":"rectangle","x":1000000,"y":0,"width":1,"height":1,"angle":0,"strokeColor":"#000000","backgroundColor":"transparent","strokeWidth":1,"opacity":100,"roundness":null,"isDeleted":false}]}"##.utf8)
        let extremeSource = try RendererEmbeddedContent.Source(
            sourceID: sourceID,
            sourceVersionID: SourceVersionID(rawValue: "01J00000000000000000000007"),
            mimeType: try .init(validating: "application/json"),
            bytes: extremeBytes)
        let extremePlan = RendererEmbedPlan(
            placeholderID: "extreme-excalidraw",
            embeddingRole: .inlineContent,
            rendererReference: exactPlan.rendererReference,
            input: .source(extremeSource),
            semanticContent: "drawing")
        #expect(DocumentRendererDOMProjector.project(extremePlan) == nil)
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

    private func sourceResolution(mime: String) -> DocumentSourceResolution {
        DocumentSourceResolution(
            sourceID: sourceID,
            version: .source(SourceVersionID(rawValue: "01J00000000000000000000004")),
            displayName: "Media",
            mimeType: mime,
            bytes: Data("bytes".utf8),
            externalTarget: nil,
            isMermaidSource: false)
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
