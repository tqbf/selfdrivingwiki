#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

struct MarkdownImageEmbedProjectionTests {
    @Test("an exact sibling target projects pinned image facts")
    func exactSiblingTargetProjectsPinnedImageFacts() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let projection = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": source],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        guard case let .interactive(candidate) = projection.outcome(for: "images/board.canvas") else {
            Issue.record("expected the exact sibling path to be interactive")
            return
        }
        #expect(candidate.rendererReference == descriptor.reference)
        #expect(candidate.source.sourceID == source.sourceID)
        #expect(candidate.source.sourceVersionID == source.sourceVersionID)
        #expect(candidate.source.mimeType == source.mimeType)
        #expect(candidate.source.bytes == Self.jsonCanvasBytes)
        #expect(candidate.source.digest == RendererSHA256.digest(Self.jsonCanvasBytes))
    }

    @Test("external unresolved and nonexact paths stay ordinary")
    func untrustedPathsStayOrdinary() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let projection = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": source],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        for target in [
            "https://example.com/board.canvas",
            "data:application/json;base64,e30=",
            "wiki-blob://source/01HUNTRUSTED",
            "images/../images/board.canvas",
            "images/missing.canvas",
        ] {
            #expect(projection.outcome(for: target) == .ordinary)
        }
    }

    @Test("descriptor capability MIME and size failures stay ordinary")
    func failedEligibilityFactsStayOrdinary() throws {
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let registry = try RendererRegistrySnapshot(builtInDescriptors: [descriptor])
        let validSource = try imageSource(bytes: Self.jsonCanvasBytes)
        let unclaimed = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": validSource],
            registry: try RendererRegistrySnapshot(builtInDescriptors: []),
            inlineCapableReferences: [])
        let unsupportedFactory = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": validSource],
            registry: registry,
            inlineCapableReferences: [])
        let wrongMIME = try imageSource(
            mimeType: "image/png",
            bytes: Self.jsonCanvasBytes)
        let oversized = try imageSource(
            bytes: Data(repeating: 0, count: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1))
        let mimeFailure = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": wrongMIME],
            registry: registry,
            inlineCapableReferences: [descriptor.reference])
        let sizeFailure = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": oversized],
            registry: registry,
            inlineCapableReferences: [descriptor.reference])

        #expect(unclaimed.outcome(for: "images/board.canvas") == .ordinary)
        #expect(unsupportedFactory.outcome(for: "images/board.canvas") == .ordinary)
        #expect(mimeFailure.outcome(for: "images/board.canvas") == .ordinary)
        #expect(sizeFailure.outcome(for: "images/board.canvas") == .ordinary)
    }

    @Test("claimed image rows preserve escaped alt text without activation metadata")
    func claimedImageRowsPreserveAltTextWithoutActivationMetadata() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let projection = try MarkdownImageEmbedProjection(
            siblingSources: ["images/board.canvas": source],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])
        let html = MarkdownHTMLRenderer.render(
            "![System <&>](images/board.canvas)",
            options: MarkdownRenderOptions(
                codeHighlighting: .disabled,
                rendererEmbedProjection: nil,
                imageEmbedProjection: projection,
                documentIdentity: nil,
                rendererActivationAdmission: nil))

        #expect(html.contains("sdw-renderer-card"))
        #expect(html.contains("System &lt;&amp;&gt;"))
        #expect(html.contains(#"<img src="images/board.canvas" alt="System &lt;&amp;&gt;">"#))
        #expect(html.contains(#"data-renderer-expanded="true""#))
        #expect(html.contains(#"aria-expanded="true""#))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-input="))
    }

    @Test("missing oversized and untrusted metadata never materialize image bytes")
    @MainActor
    func rejectedMetadataNeverReadsImageBytes() throws {
        let sourceID = SourceID(rawValue: "01HIMAGEPROJECTION0000000001")
        let version = SourceVersion(
            id: SourceVersionID(rawValue: "01HIMAGEVERSION00000000001"),
            sourceID: sourceID,
            parentID: nil,
            blobHash: "pinned-blob",
            mimeType: "application/json",
            activityID: nil,
            externalIdentity: nil,
            fetchedAt: .distantPast)
        let rejectedCounts: [Int?] = [
            nil,
            WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1,
        ]

        for byteCount in rejectedCounts {
            var readCalls = 0
            let source = try WikiReaderRep.Coordinator.pinnedImageSource(
                sourceID: sourceID,
                version: version,
                inputByteCount: { _ in byteCount },
                readBytes: { _ in
                    readCalls += 1
                    return Self.jsonCanvasBytes
                })
            #expect(source == nil)
            #expect(readCalls == 0)
        }

        var untrustedReadCalls = 0
        let untrustedSource = try WikiReaderRep.Coordinator.pinnedImageSource(
            sourceID: SourceID(rawValue: "01HUNTRUSTEDSOURCE000000001"),
            version: version,
            inputByteCount: { _ in Self.jsonCanvasBytes.count },
            readBytes: { _ in
                untrustedReadCalls += 1
                return Self.jsonCanvasBytes
            })
        #expect(untrustedSource == nil)
        #expect(untrustedReadCalls == 0)
    }

    private static let jsonCanvasBytes = Data(#"{"nodes":[],"edges":[]}"#.utf8)

    private func imageSource(
        mimeType: String = "application/json",
        bytes: Data
    ) throws -> RendererEmbeddedContent.Source {
        try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01HIMAGEPROJECTION0000000001"),
            sourceVersionID: SourceVersionID(rawValue: "01HIMAGEVERSION00000000001"),
            mimeType: try RendererMIMEType(validating: mimeType),
            bytes: bytes)
    }
}
#endif
