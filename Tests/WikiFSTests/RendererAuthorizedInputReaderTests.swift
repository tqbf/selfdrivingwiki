import Foundation
import Testing
@testable import WikiFSCore

struct RendererAuthorizedInputReaderTests {
    @Test("store-backed Markdown reads retain the authorized pinned version")
    func storeBackedMarkdownReadUsesPinnedBlobBytes() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "input.md", data: Data())
        let pinned = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "# pinned", origin: .user, note: nil
        )
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "# current", origin: .user, note: nil
        )
        let input = RendererBridgeInput.markdown(versionID: pinned.id)
        let reader = RendererAuthorizedInputReader(store: store, authorizedInput: input)

        let payload = try reader.read(input)

        #expect(payload.mimeType == "text/markdown")
        #expect(payload.bytes == Data("# pinned".utf8))
    }

    @Test("oversized pinned inputs fail before the payload reader runs")
    func oversizedPinnedInputsDoNotMaterializePayloads() throws {
        for input in [
            RendererBridgeInput.source(versionID: .init(rawValue: "source-version")),
            .markdown(versionID: .init(rawValue: "markdown-version")),
        ] {
            var payloadRead = false
            let reader = RendererAuthorizedInputReader(
                authorizedInput: input,
                inputByteCount: { requestedInput in
                    #expect(requestedInput == input)
                    return WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount + 1
                },
                readPayload: { _ in
                    payloadRead = true
                    return .init(mimeType: "text/plain", bytes: Data())
                }
            )

            #expect(throws: RendererAuthorizedInputReader.ReaderError.oversizedInput) {
                try reader.read(input)
            }
            #expect(payloadRead == false)
        }
    }

    @Test("inline artifacts round-trip without store lookup and close fail closed")
    func inlineArtifactRoundTripsAndFailsClosed() throws {
        let pageID = PageID(rawValue: "01HTESTPAGE000000000000001")
        let pageVersionID = PageVersionID(rawValue: "01HTESTPV00000000000000001")
        let bytes = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let blockID = try MarkdownBlockID(
            pageID: pageID,
            pageVersionID: pageVersionID,
            parserOrdinal: 0,
            digest: RendererSHA256.digest(bytes))
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: blockID,
            fenceKind: .jsoncanvas,
            mimeType: .init(rawValue: "application/json")!,
            bytes: bytes)
        let input = RendererBridgeInput.inlineArtifact(artifact)
        let reader = RendererAuthorizedInputReader(
            authorizedInput: input,
            inputByteCount: { requested in
                #expect(requested == input)
                return artifact.bytes.count
            },
            readPayload: { requested in
                #expect(requested == input)
                return .init(mimeType: artifact.mimeType.rawValue, bytes: artifact.bytes)
            }
        )

        let payload = try reader.read(input)
        #expect(payload.mimeType == "application/json")
        #expect(payload.bytes == bytes)

        reader.close()
        #expect(throws: RendererAuthorizedInputReader.ReaderError.closed) {
            try reader.read(input)
        }
    }
}
