#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// AC.6 built-in renderer DOM plans: parameterized PDF/HTML/audio/video plans
/// use pinned exact-version DOM elements, and byteless provider-hosted media
/// renders a readable fallback with an explicit open action (no iframe).
@Suite
@MainActor
struct BuiltInRendererDOMPlanTests {
    private let pageID = PageID(rawValue: "01HTESTPAGE0000000000000")
    private let pageVersionID = PageVersionID(rawValue: "01HTESTPAGEVERSION000001")

    private func makeContext(
        sourceVersionID: SourceVersionID,
        mimeType: String,
        bytes: Data
    ) throws -> RendererEmbedActivationContext {
        let source = try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01HTESTSOURCE00000000000000"),
            sourceVersionID: sourceVersionID,
            mimeType: try RendererMIMEType(validating: mimeType),
            bytes: bytes)
        return RendererEmbedActivationContext(
            pageID: pageID,
            pageVersionID: pageVersionID,
            identity: .source(source),
            embeddingRole: .disclosureRow,
            rendererReference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.builtin.pdf")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!,
                registrationID: RendererRegistrationID(rawValue: "pdf")!),
            input: .source(versionID: sourceVersionID),
            capability: .init(rawValue: "test-capability"),
            generation: 3)
    }

    @Test("PDF embeds pin an exact-version blob iframe")
    func pdfPlanPinsBlobIframe() throws {
        let versionID = SourceVersionID(rawValue: "01HTESTVERSION0000000000001")
        let context = try makeContext(
            sourceVersionID: versionID, mimeType: "application/pdf", bytes: Data("%PDF".utf8))
        let plan = RendererDOMEmbedPlanner.builtInPlan(context: context)
        guard case .pdfFrame(let framePlan) = plan else {
            Issue.record("expected pdfFrame plan, got \(String(describing: plan))")
            return
        }
        #expect(framePlan.blobURL.host == BlobSchemeHandler.sourceVersionHost)
        #expect(framePlan.blobURL.path == "/\(versionID.rawValue)")
        #expect(framePlan.blobURL.scheme == "wiki-blob")
        #expect(framePlan.boundedHeight == RendererDOMEmbedMetrics.nearSquareHeight)
        #expect(framePlan.accessibleTitle.isEmpty == false)
        // Injection script creates an iframe with the pinned URL and lazy load.
        let script = RendererDOMEmbedInjection.injectionScript(
            plan: plan!, placeholderID: try RendererAttachmentPlaceholderID(validating: "row"),
            expansionID: "row-expansion")
        #expect(script?.contains("sdwInjectRendererEmbed") == true)
        #expect(script?.contains("wiki-blob://source-version/\(versionID.rawValue)") == true)
    }

    @Test("raw HTML embeds are inert iframes without allow-scripts")
    func htmlPlanOmitsAllowScripts() throws {
        let versionID = SourceVersionID(rawValue: "01HTESTVERSION0000000000002")
        let context = try makeContext(
            sourceVersionID: versionID, mimeType: "text/html", bytes: Data("<p>hi</p>".utf8))
        let plan = RendererDOMEmbedPlanner.builtInPlan(context: context)
        guard case .inertHTMLFrame(let framePlan) = plan else {
            Issue.record("expected inertHTMLFrame plan, got \(String(describing: plan))")
            return
        }
        // allow-scripts is deliberately absent; everything unlisted stays denied.
        #expect(framePlan.sandboxFlags?.contains("allow-scripts") == false)
        #expect(framePlan.blobURL.path == "/\(versionID.rawValue)")
    }

    @Test("byte-backed audio and video become DOM media elements")
    func audioVideoPlansUseMediaElements() throws {
        let audioContext = try makeContext(
            sourceVersionID: SourceVersionID(rawValue: "01HTESTVERSION0000000000003"),
            mimeType: "audio/mpeg", bytes: Data([0xFF, 0xFB]))
        let videoContext = try makeContext(
            sourceVersionID: SourceVersionID(rawValue: "01HTESTVERSION0000000000004"),
            mimeType: "video/mp4", bytes: Data([0x00, 0x00, 0x00]))

        guard case .audioElement(let audioPlan) = RendererDOMEmbedPlanner.builtInPlan(context: audioContext) else {
            Issue.record("expected audioElement plan")
            return
        }
        #expect(audioPlan.kind == .audio)
        #expect(audioPlan.blobURL.scheme == "wiki-blob")
        #expect(RendererMediaElementPlan.preloadPolicy == "metadata")

        guard case .videoElement(let videoPlan) = RendererDOMEmbedPlanner.builtInPlan(context: videoContext) else {
            Issue.record("expected videoElement plan")
            return
        }
        #expect(videoPlan.kind == .video)
        #expect(videoPlan.blobURL.path.contains("01HTESTVERSION0000000000004"))
    }

    @Test("byteless provider-hosted media renders a readable fallback with an open action, no iframe")
    func bytelessMediaRendersReadableFallback() throws {
        let versionID = SourceVersionID(rawValue: "01HTESTVERSION0000000000005")
        // Byteless source: empty bytes (provider-hosted media shape).
        let context = try makeContext(
            sourceVersionID: versionID, mimeType: "video/youtube", bytes: Data())
        let plan = RendererDOMEmbedPlanner.builtInPlan(context: context)
        guard case .readableFallback(let fallback) = plan else {
            Issue.record("expected readableFallback plan, got \(String(describing: plan))")
            return
        }
        #expect(fallback.openActionLabel.contains("Open"))
        #expect(fallback.explanation.isEmpty == false)
        // No injection script exists for a fallback: no iframe is created.
        let script = RendererDOMEmbedInjection.injectionScript(
            plan: plan!, placeholderID: try RendererAttachmentPlaceholderID(validating: "row"),
            expansionID: "row-expansion")
        #expect(script == nil)
    }

    @Test("markdown-version inputs have no blob route and yield no plan")
    func markdownInputYieldsNoPlan() throws {
        // A source whose pin is a markdown version (no sourceVersionID) has
        // no blob route; the planner returns nil rather than guessing.
        let source = try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01HTESTSOURCE00000000000000"),
            sourceMarkdownVersionID: SourceMarkdownVersionID(rawValue: "01HTESTMDVERSION000000000001"),
            mimeType: try RendererMIMEType(validating: "application/pdf"),
            bytes: Data("%PDF".utf8))
        let context = RendererEmbedActivationContext(
            pageID: pageID,
            pageVersionID: pageVersionID,
            identity: .source(source),
            embeddingRole: .disclosureRow,
            rendererReference: RendererReference(
                packageID: RendererPackageID(rawValue: "org.selfdrivingwiki.builtin.pdf")!,
                version: RendererPackageVersion(rawValue: "1.0.0")!,
                registrationID: RendererRegistrationID(rawValue: "pdf")!),
            input: .markdown(versionID: SourceMarkdownVersionID(rawValue: "01HTESTMDVERSION000000000001")),
            capability: .init(rawValue: "test-capability"),
            generation: 3)
        #expect(RendererDOMEmbedPlanner.builtInPlan(context: context) == nil)
    }

    @Test("unsupported MIME yields no plan and keeps the fallback")
    func unsupportedMIMEYieldsNoPlan() throws {
        let context = try makeContext(
            sourceVersionID: SourceVersionID(rawValue: "01HTESTVERSION0000000000006"),
            mimeType: "application/octet-stream", bytes: Data([0x00]))
        #expect(RendererDOMEmbedPlanner.builtInPlan(context: context) == nil)
    }
}
#endif
