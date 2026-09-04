#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

struct TypedMarkdownHTMLRendererTests {
    @Test func overlayRendersWikiLinkOnceWithOrdinaryMarkdownAroundIt() {
        let prepared = ReaderMarkdown.preparedDocument("**before** [[Page|label]] *after* π")
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)

        #expect(html.contains("<strong>before</strong>"))
        #expect(html.contains(">label</a>"))
        #expect(html.components(separatedBy: ">label</a>").count == 2)
        #expect(html.contains("<em>after</em> π"))
        #expect(!html.contains(">[[Page"))
    }

    @Test func mermaidSourceEmbedWithAPackageClaimRendersInlineRenderer() throws {
        // A claimed .mmd source embed lowers through the generic inline
        // renderer arm — the same markup as any other package source, with
        // no host diagram markup.
        let prepared = ReaderMarkdown.preparedDocument("Diagram: ![[source:diagram.mmd]]")
        let embed = try firstEmbed(prepared)
        let source = try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01JTYPMERMAIDSRC0000000001"),
            sourceVersionID: SourceVersionID(rawValue: "01JTYPMERMAIDSRCVER0001"),
            mimeType: try .init(validating: "text/mermaid"),
            fileExtension: "mmd",
            bytes: Data("graph TD; A-->B".utf8))
        let resolved = ResolvedDocumentEmbed.renderer(
            syntax: .wikiSourceMedia(embed),
            role: .inlineContent,
            plan: RendererEmbedPlan(
                placeholderID: "typed-mermaid-inline",
                embeddingRole: .inlineContent,
                rendererReference: RendererReference(
                    packageID: PackageFenceTestSupport.installedMermaidDescriptor().reference.packageID,
                    version: PackageFenceTestSupport.installedMermaidDescriptor().reference.version,
                    registrationID: PackageFenceTestSupport.installedMermaidDescriptor().reference.registrationID),
                input: .source(source),
                semanticContent: "diagram",
                activationMetadata: .init(
                    controlLabel: "Open",
                    accessibilityLabel: "Open inline source renderer",
                    summary: "Open the source in the renderer pane.")),
            fallback: .code(language: "mermaid", source: "graph TD; A-->B"))
        let projection = ResolvedDocumentProjection(wikiEmbeds: [embed.sourceRange: resolved])

        let html = MarkdownHTMLRenderer.render(prepared, projection: projection, options: .disabled)
        #expect(html.contains("sdw-inline-renderer"))
        #expect(html.contains("data-renderer-role=\"inlineContent\""))
        #expect(!html.contains("sdw-inline-mermaid"))
        #expect(!html.contains("sdw-renderer-card__row"))
        #expect(!html.contains("sdw-renderer-card__disclosure"))
    }

    @Test func authoredMermaidFenceRendersDisclosureRow() {
        let identity = MarkdownDocumentIdentity(
            pageID: PageID(rawValue: "01J00000000000000000000001"),
            pageVersionID: PageVersionID(rawValue: "01J00000000000000000000002"))
        let prepared = ReaderMarkdown.preparedDocument(
            "```mermaid\ngraph TD; A-->B\n```",
            documentIdentity: identity)
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: .init(),
            options: .init(
                codeHighlighting: .disabled,
                rendererEmbedProjection: .init(
                    sourceEmbeds: [:],
                    richFenceClaims: RendererFenceClaimResolver.resolve(
                        builtInDescriptors: [],
                        availableInstalledDescriptors: [PackageFenceTestSupport.installedMermaidDescriptor()])),
                documentIdentity: identity,
                rendererActivationAdmission: nil))

        #expect(html.contains("sdw-renderer-card__row"))
        #expect(html.contains("sdw-renderer-card__disclosure"))
    }

    @Test func pageEmbedLowersToTypedLazyTransclusion() throws {
        let prepared = ReaderMarkdown.preparedDocument("![[Page#Details|More]]")
        let embed = try firstEmbed(prepared)
        let pageID = PageID(rawValue: "01J00000000000000000000003")
        let projection = ResolvedDocumentProjection(wikiEmbeds: [
            embed.sourceRange: .transclusion(
                target: .page(pageID),
                display: .init(title: "More", altText: nil),
                fragment: "Details",
                ancestors: [])
        ])

        let html = MarkdownHTMLRenderer.render(prepared, projection: projection, options: .disabled)
        #expect(html.contains("class=\"sdw-transclusion\""))
        #expect(html.contains("data-sdw-embed-kind=\"page\""))
        #expect(html.contains("data-sdw-embed-id=\"\(pageID.rawValue)\""))
        #expect(html.contains("data-sdw-embed-fragment=\"Details\""))
    }

    @Test func codeProtectedWikiSyntaxRemainsLiteral() {
        let prepared = ReaderMarkdown.preparedDocument("`[[Code]]` and [[Live]]")
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.contains("<code>[[Code]]</code>"))
        #expect(html.contains(">Live</a>"))
    }

    private func permissiveProjection(
        for prepared: PreparedMarkdownDocument
    ) -> ResolvedDocumentProjection {
        DocumentEmbedResolver(inputs: .init(assumeLinksResolved: true))
            .projection(for: prepared, resolveEmbeds: false)
    }

    private func firstEmbed(_ prepared: PreparedMarkdownDocument) throws -> WikiMarkdownSyntaxNode.Embed {
        guard let node = prepared.wikiSyntax.first,
              case .embed(let embed) = node else {
            throw TestError.expectedEmbed
        }
        return embed
    }

    private enum TestError: Error { case expectedEmbed }
}
#endif
