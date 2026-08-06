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

            #expect(throws: RendererBridgeAuthorizationError.oversizedPayload) {
                try reader.read(input)
            }
            #expect(payloadRead == false)
        }
    }
}
