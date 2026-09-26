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

    /// A wiki link whose label wraps onto the next source line spans a
    /// range-less `SoftBreak`. The paragraph's other Markdown must still render,
    /// and the link must render once, not as authored literal text.
    @Test func wikiLinkWrappedAcrossSoftBreakRendersParagraphMarkdown() {
        let prepared = ReaderMarkdown.preparedDocument(
            "**Barriers** stop a [[page:01KWRYQKPE2G145H22H6BYSSN8|taint\nanalysis]] uses to *stop* flow.")
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.contains("<strong>Barriers</strong>"))
        #expect(html.contains("<em>stop</em>"))
        #expect(html.components(separatedBy: "</a>").count == 2)
        #expect(!html.contains("[["))
        #expect(!html.contains("]]"))
        #expect(html.contains("</a> uses to"))
    }

    /// A range-less `SoftBreak` *before* an ordinary, single-line wiki link
    /// must not fail the whole paragraph closed either — only a spanning
    /// overlay should open a span; an unrelated line break earlier in the
    /// same container must fall through to ordinary rendering.
    @Test func softBreakBeforeSingleLineWikiLinkRendersParagraphMarkdown() {
        let prepared = ReaderMarkdown.preparedDocument(
            "Barriers stop a taint\nanalysis uses [[page:01KWRYQKPE2G145H22H6BYSSN8|flow]] to *stop* it.")
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.contains("<em>stop</em>"))
        #expect(html.components(separatedBy: "</a>").count == 2)
        #expect(!html.contains("[["))
        #expect(!html.contains("]]"))
        #expect(html.contains(">flow</a>"))
    }

    /// Two wiki links in one paragraph, the first wrapped across a line: the
    /// wrapped overlay must close its span cleanly and let the second,
    /// ordinary link resolve normally afterward.
    @Test func twoWikiLinksWithFirstWrappedAcrossSoftBreakBothRenderOnce() {
        let prepared = ReaderMarkdown.preparedDocument(
            "A [[page:01KWRYQKPE2G145H22H6BYSSN8|taint\nanalysis]] uses [[page:01KWRYQKPE2G145H22H6BYSSN9|flow]] to stop it."
        )
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.components(separatedBy: "</a>").count == 3)
        #expect(!html.contains("[["))
        #expect(!html.contains("]]"))
        #expect(html.contains(">taint analysis</a>"))
        #expect(html.contains(">flow</a>"))
    }

    /// A wrapped link's tail leaf carries more authored text *and* another
    /// wiki link — `renderTextRange` must keep handling overlays after the
    /// span closes, within the same leaf.
    @Test func wrappedLinkFollowedByAnotherLinkInTailLeafRendersBoth() {
        let prepared = ReaderMarkdown.preparedDocument(
            "A [[page:01KWRYQKPE2G145H22H6BYSSN8|taint\nanalysis]] uses to reach [[page:01KWRYQKPE2G145H22H6BYSSN9|flow]] here."
        )
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.components(separatedBy: "</a>").count == 3)
        #expect(!html.contains("[["))
        #expect(!html.contains("]]"))
        #expect(html.contains("</a> uses to reach"))
        #expect(html.contains(">flow</a>"))
    }

    /// The leaf that opens a wrapped link already holds an earlier link, so the
    /// span must open from inside the ordinary text-range split.
    @Test func wrappedLinkOpeningInLeafWithEarlierLinkRendersBoth() {
        let prepared = ReaderMarkdown.preparedDocument(
            "See [[page:01KWRYQKPE2G145H22H6BYSSN9|flow]] and a [[page:01KWRYQKPE2G145H22H6BYSSN8|taint\nanalysis]] tail *end*."
        )
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.components(separatedBy: "</a>").count == 3)
        #expect(!html.contains("[["))
        #expect(!html.contains("]]"))
        #expect(html.contains("</a> and a <a"))
        #expect(html.contains("</a> tail <em>end</em>"))
    }

    /// The second wrapped link opens inside the first link's closing leaf.
    @Test func consecutiveWrappedLinksBothRenderOnce() {
        let prepared = ReaderMarkdown.preparedDocument(
            "A [[page:01KWRYQKPE2G145H22H6BYSSN8|taint\nanalysis]] and [[page:01KWRYQKPE2G145H22H6BYSSN9|flow\nguard]] *end*."
        )
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: permissiveProjection(for: prepared),
            options: .disabled)
        #expect(html.components(separatedBy: "</a>").count == 3)
        #expect(!html.contains("[["))
        #expect(!html.contains("]]"))
        #expect(html.contains("</a> and <a"))
        #expect(html.contains("</a> <em>end</em>"))
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
