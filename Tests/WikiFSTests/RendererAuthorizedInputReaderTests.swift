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

    @Test("admitted source reads require exact pinned bytes MIME digest and typed version", arguments: [false, true])
    func admittedSourceReadsRequireExactPinnedPayload(useMarkdownVersion: Bool) throws {
        let store = try GRDBWikiStore()
        let stored = try store.addSource(filename: "admitted.json", data: Data("source-bytes".utf8))
        let source: RendererEmbeddedContent.Source
        let input: RendererBridgeInput
        if useMarkdownVersion {
            let version = try store.appendProcessedMarkdown(
                sourceID: stored.id, content: "markdown-bytes", origin: .user, note: nil)
            input = .markdown(versionID: version.id)
            source = try .init(
                sourceID: stored.id,
                sourceMarkdownVersionID: version.id,
                mimeType: try RendererMIMEType(validating: "text/markdown"),
                bytes: Data("markdown-bytes".utf8))
        } else {
            let version = try #require(try store.activeContentVersion(sourceID: stored.id))
            input = .source(versionID: version.id)
            source = try .init(
                sourceID: stored.id,
                sourceVersionID: version.id,
                mimeType: try RendererMIMEType(validating: version.mimeType ?? "application/octet-stream"),
                bytes: Data("source-bytes".utf8))
        }
        let reader = try RendererAuthorizedInputReader(
            store: store,
            authorizedInput: input,
            admittedSource: source)

        let payload = try reader.read(input)

        #expect(payload.mimeType == source.mimeType.rawValue)
        #expect(payload.bytes == source.bytes)
        #expect(RendererSHA256.digest(payload.bytes) == source.digest)
    }

    @Test("admitted source reader rejects mismatched typed versions")
    func admittedSourceReaderRejectsMismatchedTypedVersion() throws {
        let store = try GRDBWikiStore()
        let stored = try store.addSource(filename: "admitted.json", data: Data("source-bytes".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: stored.id))
        let source = try RendererEmbeddedContent.Source(
            sourceID: stored.id,
            sourceVersionID: version.id,
            mimeType: try RendererMIMEType(validating: version.mimeType ?? "application/octet-stream"),
            bytes: Data("source-bytes".utf8))

        #expect(throws: RendererAuthorizedInputReader.ReaderError.unauthorizedInput) {
            _ = try RendererAuthorizedInputReader(
                store: store,
                authorizedInput: .source(versionID: SourceVersionID(rawValue: "other-version")),
                admittedSource: source)
        }
        #expect(throws: RendererAuthorizedInputReader.ReaderError.unauthorizedInput) {
            _ = try RendererAuthorizedInputReader(
                store: store,
                authorizedInput: .markdown(versionID: SourceMarkdownVersionID(rawValue: version.id.rawValue)),
                admittedSource: source)
        }
    }

    @Test("admitted source reader rejects store MIME and byte drift")
    func admittedSourceReaderRejectsStorePayloadDrift() throws {
        let store = try GRDBWikiStore()
        let stored = try store.addSource(filename: "admitted.json", data: Data("stored-bytes".utf8))
        let version = try #require(try store.activeContentVersion(sourceID: stored.id))
        let input = RendererBridgeInput.source(versionID: version.id)
        let admittedMIME = try RendererEmbeddedContent.Source(
            sourceID: stored.id,
            sourceVersionID: version.id,
            mimeType: try RendererMIMEType(validating: "image/png"),
            bytes: Data("stored-bytes".utf8))
        let admittedBytes = try RendererEmbeddedContent.Source(
            sourceID: stored.id,
            sourceVersionID: version.id,
            mimeType: try RendererMIMEType(validating: version.mimeType ?? "application/octet-stream"),
            bytes: Data("different-bytes".utf8))

        for admittedSource in [admittedMIME, admittedBytes] {
            let reader = try RendererAuthorizedInputReader(
                store: store,
                authorizedInput: input,
                admittedSource: admittedSource)
            #expect(throws: RendererAuthorizedInputReader.ReaderError.unavailablePinnedInput) {
                try reader.read(input)
            }
        }
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
        let block = try MarkdownFencedBlock(
            documentIdentity: .init(pageID: pageID, pageVersionID: pageVersionID),
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        let blockID = try #require(block.blockID)
        let artifact = try RendererEmbeddedContent.InlineArtifact(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: blockID,
            fenceAlias: RendererFenceAlias(rawValue: "jsoncanvas")!,
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

        #expect(block.digest == artifact.digest)
        let payload = try reader.read(input)
        #expect(payload.mimeType == "application/json")
        #expect(payload.bytes == bytes)

        reader.close()
        #expect(throws: RendererAuthorizedInputReader.ReaderError.closed) {
            try reader.read(input)
        }
    }

    @MainActor
    @Test("composition seam resolves the exact pinned reader for the requested source")
    func resolverSeamReturnsTheExactPinnedReader() throws {
        let store = try GRDBWikiStore()
        let source = try store.addSource(filename: "reader-seam.md", data: Data("# seam".utf8))
        let resolver: any RendererAuthorizedInputResolving = WikiStoreModel(store: store)
        let reader = try #require(resolver.rendererAuthorizedInputReader(for: source.id))
        let version = try #require(try store.activeContentVersion(sourceID: source.id))

        #expect(reader.authorizedInput == RendererBridgeInput.source(versionID: version.id))
    }
}
