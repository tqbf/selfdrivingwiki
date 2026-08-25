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

    private enum TestError: Error { case expectedEmbed }
}
#endif
