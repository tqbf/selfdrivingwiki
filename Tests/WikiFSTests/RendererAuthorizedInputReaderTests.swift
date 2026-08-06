import Foundation
import Testing
@testable import WikiFSCore

struct RendererAuthorizedInputReaderTests {
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
