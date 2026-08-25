#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

struct MarkdownImageTargetProjectionTests {
    @Test("an exact sibling target projects pinned image facts")
    func exactSiblingTargetProjectsPinnedImageFacts() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let targets = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": source],
            siblingSourceIDs: ["images/board.canvas": source.sourceID],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        guard case let .renderer(reference, pinnedSource) = targets["images/board.canvas"] else {
            Issue.record("expected the exact sibling path to select an inline renderer")
            return
        }
        #expect(reference == descriptor.reference)
        #expect(pinnedSource.sourceID == source.sourceID)
        #expect(pinnedSource.sourceVersionID == source.sourceVersionID)
        #expect(pinnedSource.mimeType == source.mimeType)
        #expect(pinnedSource.bytes == Self.jsonCanvasBytes)
        #expect(pinnedSource.digest == RendererSHA256.digest(Self.jsonCanvasBytes))
    }

    @Test("external unresolved and nonexact paths stay ordinary")
    func untrustedPathsStayOrdinary() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let targets = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": source],
            siblingSourceIDs: ["images/board.canvas": source.sourceID],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])

        for target in [
            "https://example.com/board.canvas",
            "data:application/json;base64,e30=",
            "wiki-blob://source/01HUNTRUSTED",
            "images/../images/board.canvas",
            "images/missing.canvas",
        ] {
            #expect(targets[target] == nil)
        }
    }

    @Test("descriptor capability MIME and size failures stay ordinary")
    func failedEligibilityFactsStayOrdinary() throws {
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let registry = try RendererRegistrySnapshot(builtInDescriptors: [descriptor])
        let validSource = try imageSource(bytes: Self.jsonCanvasBytes)
        let siblingIDs = ["images/board.canvas": validSource.sourceID]
        let unclaimed = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": validSource],
            siblingSourceIDs: siblingIDs,
            registry: try RendererRegistrySnapshot(builtInDescriptors: []),
            inlineCapableReferences: [])
        let unsupportedFactory = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": validSource],
            siblingSourceIDs: siblingIDs,
            registry: registry,
            inlineCapableReferences: [])
        let wrongMIME = try imageSource(
            mimeType: "image/png",
            bytes: Self.jsonCanvasBytes)
        let oversized = try imageSource(
            bytes: Data(repeating: 0, count: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1))
        let mimeFailure = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": wrongMIME],
            siblingSourceIDs: siblingIDs,
            registry: registry,
            inlineCapableReferences: [descriptor.reference])
        let sizeFailure = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": oversized],
            siblingSourceIDs: siblingIDs,
            registry: registry,
            inlineCapableReferences: [descriptor.reference])
        let blobTarget = ResolvedMarkdownImageTarget.blob(validSource.sourceID)

        #expect(unclaimed["images/board.canvas"] == blobTarget)
        #expect(unsupportedFactory["images/board.canvas"] == blobTarget)
        #expect(mimeFailure["images/board.canvas"] == blobTarget)
        #expect(sizeFailure["images/board.canvas"] == blobTarget)
    }

    @Test("claimed images stay inline and preserve escaped fallback alt text")
    func claimedImagesStayInlineWithReadableFallback() throws {
        let source = try imageSource(bytes: Self.jsonCanvasBytes)
        let descriptor = BuiltInRendererDescriptors.descriptor(for: .jsonCanvas)
        let targets = try MarkdownImageTargetProjection.build(
            siblingSources: ["images/board.canvas": source],
            siblingSourceIDs: ["images/board.canvas": source.sourceID],
            registry: try RendererRegistrySnapshot(builtInDescriptors: [descriptor]),
            inlineCapableReferences: [descriptor.reference])
        let prepared = ReaderMarkdown.preparedDocument("![System <&>](images/board.canvas)")
        let projection = ResolvedDocumentProjection(markdownImages: targets)
        let html = MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: .disabled)

        #expect(html.contains("sdw-inline-renderer"))
        #expect(html.contains("data-renderer-role=\"inlineContent\""))
        #expect(html.contains("System &lt;&amp;&gt;"))
        #expect(html.contains(#"<img src="wiki-blob://source/01HIMAGEPROJECTION0000000001" alt="System &lt;&amp;&gt;">"#))
        #expect(!html.contains("sdw-renderer-card__row"))
        #expect(!html.contains("sdw-renderer-card__disclosure"))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-admitted=\"true\""))
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
