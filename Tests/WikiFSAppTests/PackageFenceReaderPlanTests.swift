#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Reader-side package-declared fence behavior: the d2 fence produces a
/// data-driven embed plan through the installed package's claim, an alias
/// without an available claimant degrades to the typed raw-code fallback, and
/// the three pre-existing aliases keep byte-identical reader output.
@Suite("Package fence reader plans")
@MainActor
struct PackageFenceReaderPlanTests {
    private static let document = MarkdownDocumentIdentity(
        pageID: PageID(rawValue: "01HTESTPAGE000000000000001"),
        pageVersionID: PageVersionID(rawValue: "01HTESTPV00000000000000001"))

    private static func options(
        claims: [RendererFenceAlias: RendererFenceClaimAssignment],
        unavailableFenceAliases: Set<RendererFenceAlias> = []
    ) -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: RendererEmbedProjection(
                sourceEmbeds: [:],
                richFenceClaims: claims,
                unavailableFenceAliases: unavailableFenceAliases),
            documentIdentity: document,
            rendererActivationAdmission: RendererEmbedActivationAdmission(
                pageID: document.pageID,
                pageVersionID: document.pageVersionID,
                capability: .init(rawValue: "capability"),
                generation: 1))
    }

    /// A stand-in for the generated D2 package descriptor (see
    /// ``PackageFenceTestSupport/d2Descriptor()``).
    private static func d2Descriptor() throws -> RendererDescriptor {
        PackageFenceTestSupport.d2Descriptor()
    }

    /// The bundled Excalidraw descriptor as the shipped manifest declares it
    /// (see ``PackageFenceTestSupport/installedExcalidrawDescriptor()``).
    private static func installedExcalidrawDescriptor() throws -> RendererDescriptor {
        PackageFenceTestSupport.installedExcalidrawDescriptor()
    }

    // MARK: - AC.1: the d2 fence renders through the installed package's claim

    @Test("a d2 fence produces a renderer card from the package claim alone")
    func d2FenceRendersFromClaimData() throws {
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [try Self.d2Descriptor()])
        let html = MarkdownHTMLRenderer.render(
            "```d2\nx -> y\n```",
            options: Self.options(claims: claims))

        #expect(html.contains("sdw-renderer-card"))
        #expect(html.contains("data-renderer-reference=\"org.selfdrivingwiki.d2-readonly/1.0.0/d2\""))
        #expect(html.contains("aria-label=\"D2 renderer\""))
        // Derived presentation: display name, not a per-format host string.
        #expect(html.contains("D2 fence"))
        #expect(html.contains("Expand D2 renderer"))
        // The claim's alias and MIME ride on the authorized inline artifact.
        #expect(html.contains("&quot;fenceAlias&quot;:&quot;d2&quot;"))
        #expect(html.contains("&quot;mimeType&quot;:&quot;text\\/plain&quot;"))
        #expect(html.contains("renderer-action://open"))
    }

    @Test("an alias nothing ever claimed stays silent plain code")
    func unclaimedAliasStaysSilentPlainCode() {
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all)
        let options = Self.options(claims: claims)

        for alias in ["d2", "bash", "python", "yaml"] {
            let html = MarkdownHTMLRenderer.render(
                "```\(alias)\nx -> y\n```",
                options: options)
            #expect(html.contains(#"<pre><code class="language-\#(alias)">"#), "plain code for \(alias)")
            #expect(!html.contains("sdw-renderer-card__fallback"), "no fallback notice for \(alias)")
            #expect(!html.contains("sdw-renderer-card\""), "no card for \(alias)")
        }
    }

    @Test("a removed or suppressed claimant explains its typed fallback")
    func unavailableClaimantFallsBackWithNotice() throws {
        let d2 = try #require(RendererFenceAlias(rawValue: "d2"))
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all)
        let html = MarkdownHTMLRenderer.render(
            "```d2\nx -> y\n```",
            options: MarkdownRenderOptions(
                codeHighlighting: .disabled,
                rendererEmbedProjection: RendererEmbedProjection(
                    sourceEmbeds: [:],
                    richFenceClaims: claims,
                    unavailableFenceAliases: [d2]),
                documentIdentity: Self.document,
                rendererActivationAdmission: nil))

        #expect(html.contains(#"<pre><code class="language-d2">x -&gt; y"#))
        #expect(html.contains("sdw-renderer-card__fallback"))
        #expect(html.contains("The renderer for this block is not available here."))
        #expect(!html.contains("sdw-renderer-card\""))
    }

    @Test("the store remembers a claimant it has served and flags its removal")
    func storeMarksRemovedClaimantUnavailable() throws {
        let store = try GRDBWikiStore()
        let model = WikiStoreModel(store: store)
        model.rendererBuiltInDescriptors = BuiltInRendererDescriptors.all
        model.rendererAvailableDescriptors = [PackageFenceTestSupport.d2Descriptor()]
        let d2 = try #require(RendererFenceAlias(rawValue: "d2"))

        let whileInstalled = model.renderContext()
        #expect(whileInstalled.rendererEmbedProjection.fenceClaim(for: d2) != nil)
        #expect(whileInstalled.rendererEmbedProjection.unavailableFenceAliases.isEmpty)

        // Registry refresh drops the claimant; the next context flags it.
        model.rendererAvailableDescriptors = []
        let afterRemoval = model.renderContext()
        #expect(afterRemoval.rendererEmbedProjection.fenceClaim(for: d2) == nil)
        #expect(afterRemoval.rendererEmbedProjection.unavailableFenceAliases.contains(d2))

        // Reinstall restores rendering from the same session state.
        model.rendererAvailableDescriptors = [PackageFenceTestSupport.d2Descriptor()]
        let reinstalled = model.renderContext()
        #expect(reinstalled.rendererEmbedProjection.fenceClaim(for: d2) != nil)
        #expect(!reinstalled.rendererEmbedProjection.unavailableFenceAliases.contains(d2))
    }

    @Test("a projection-less render keeps unclaimed fences inert")
    func projectionlessRenderStaysInert() {
        let html = MarkdownHTMLRenderer.render(
            "```d2\nx -> y\n```",
            options: MarkdownRenderOptions(
                codeHighlighting: .disabled,
                rendererEmbedProjection: nil,
                documentIdentity: Self.document,
                rendererActivationAdmission: nil))
        #expect(html == "<pre><code class=\"language-d2\">x -&gt; y\n</code></pre>")
    }

    // MARK: - AC.3: golden output for the remaining built-in and package aliases

    @Test("a claimed mermaid fence renders the generic package card")
    func mermaidGoldenThroughPackageClaim() {
        // The built-in claim is gone; the reviewed package claims the alias
        // now, so the fence renders the generic card path — the same markup
        // D2 and Excalidraw produce — with presentation strings derived from
        // descriptor data.
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [PackageFenceTestSupport.installedMermaidDescriptor()])
        let html = MarkdownHTMLRenderer.render(
            "```mermaid\ngraph TD\nA-->B\n```",
            options: Self.options(claims: claims))
        #expect(html.contains("sdw-renderer-card__row"))
        #expect(html.contains("data-renderer-reference=\"org.selfdrivingwiki.mermaid-readonly/1.0.0/mermaid\""))
        #expect(html.contains("aria-label=\"Mermaid renderer\""))
        #expect(html.contains("aria-label=\"Expand Mermaid renderer\""))
        #expect(html.contains("Mermaid renderer"))
        // No host mermaid markup exists.
        #expect(html.contains("sdw-mermaid-row__diagram") == false)
        #expect(html.contains("data-mermaid-disclosure") == false)
        #expect(html.contains("data-renderer-kind=\"mermaid\"") == false)
    }

    @Test("an unclaimed mermaid fence falls back to typed raw code with the notice")
    func unclaimedMermaidFenceFallsBackWithNotice() {
        // Nothing claims the alias: the fence keeps its typed raw-code
        // presentation. The generic unavailable-claim fallback adds the
        // notice once the store has seen the alias claimed.
        let html = MarkdownHTMLRenderer.render(
            "```mermaid\ngraph TD\nA-->B\n```",
            options: Self.options(claims: [:], unavailableFenceAliases: [
                RendererFenceAlias(rawValue: "mermaid")!,
            ]))
        #expect(html.contains(#"<pre><code class="language-mermaid">graph TD"#))
        #expect(html.contains("sdw-renderer-card__fallback"))
    }

    @Test("jsoncanvas fence plan carries its pinned presentation")
    func jsonCanvasGolden() throws {
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all)
        let html = MarkdownHTMLRenderer.render(
            "```jsoncanvas\n{\"nodes\":[],\"edges\":[]}\n```",
            options: Self.options(claims: claims))
        #expect(html.contains("data-renderer-reference=\"org.selfdrivingwiki.builtin/1.0.0/json-canvas\""))
        #expect(html.contains("JSON Canvas document fence"))
        #expect(html.contains("aria-label=\"JSON Canvas renderer\""))
        #expect(html.contains("aria-label=\"Expand JSON Canvas renderer\""))
        if let payload = rendererBridgeInputJSONPayload(in: html) {
            // JSONEncoder escapes the slash in "application/json".
            #expect(payload.contains("application"))
            #expect(payload.contains("json"))
            #expect(payload.contains("fenceAlias"))
        }
    }

    @Test("installed package fence plan derives presentation from its descriptor")
    func excalidrawGolden() throws {
        let claims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            availableInstalledDescriptors: [try Self.installedExcalidrawDescriptor()])
        let html = MarkdownHTMLRenderer.render(
            "```excalidraw\n{\"type\":\"excalidraw\",\"version\":2,\"elements\":[]}\n```",
            options: Self.options(claims: claims))
        #expect(html.contains(
            "data-renderer-reference=\"org.selfdrivingwiki.excalidraw-readonly/1.0.5/excalidraw\""))
        #expect(html.contains("Excalidraw fence"))
        #expect(html.contains("aria-label=\"Excalidraw renderer\""))
        #expect(html.contains("aria-label=\"Expand Excalidraw renderer\""))
    }

    // MARK: - AC.3: artifact digest invariance across the fenceKind → fenceAlias rename

    @Test("inline artifact digests keep flowing from the alias raw values")
    func artifactDigestInvariance() throws {
        for alias in ["mermaid", "jsoncanvas", "excalidraw", "d2"] {
            let fenceAlias = try #require(RendererFenceAlias(rawValue: alias))
            let bytes = Data("payload-for-\(alias)".utf8)
            let block = try MarkdownFencedBlock(
                documentIdentity: Self.document,
                parserOrdinal: 3,
                rawInfoString: alias,
                bytes: bytes)
            let blockID = try #require(block.blockID)
            let artifact = try RendererEmbeddedContent.InlineArtifact(
                pageID: Self.document.pageID,
                pageVersionID: Self.document.pageVersionID,
                blockID: blockID,
                fenceAlias: fenceAlias,
                mimeType: RendererMIMEType(rawValue: "text/plain")!,
                bytes: bytes)
            // The digest is driven by the alias *raw value*, which the rename
            // preserved: it equals an independent digest over the documented
            // canonical input spelled with the raw string.
            let independent = RendererSHA256.digest(
                MarkdownFencedBlock.canonicalDigestInput(
                    bytes: bytes,
                    normalizedInfoString: alias))
            #expect(artifact.digest == independent, "digest must follow the alias raw value: \(alias)")
        }
    }

    @Test("ordinary language labels cannot be claimed by packages")
    func ordinaryLanguageLabelsCannotBeClaimedByPackages() throws {
        // The app wiring folds the syntax-reserved labels into the injected
        // reserved set alongside the built-in claims.
        let reserved = BuiltInRendererDescriptors.reservedFenceAliases
        for token in MarkdownFenceInfo.ordinaryLanguageTokens {
            let alias = try #require(RendererFenceAlias(rawValue: token))
            #expect(reserved.contains(alias), "packages cannot claim \(token)")
        }
    }

    // MARK: - Helpers

    private func rendererBridgeInputJSONPayload(in html: String) -> String? {
        guard let range = html.range(of: "data-renderer-input=\"") else { return nil }
        let rest = html[range.upperBound...]
        guard let end = rest.range(of: "\" data-renderer") ?? rest.range(of: "\"><span") else {
            return String(rest.prefix(0))
        }
        return String(rest[..<end.lowerBound])
    }
}
#endif
