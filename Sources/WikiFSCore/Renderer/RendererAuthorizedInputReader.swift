import Foundation

// pattern: Imperative Shell

/// Reads only the immutable input version pinned when a renderer session began.
/// This intentionally has no SourceID-based API, which prevents an accidental
/// call to the live-ref `WikiStore.sourceContent(id:)` path.
public struct RendererAuthorizedInputReader {
    private let inputByteCount: (RendererBridgeInput) throws -> Int?
    private let readPayload: (RendererBridgeInput) throws -> RendererBridgeInputPayload
    public let authorizedInput: RendererBridgeInput

    public init(store: any WikiStore, authorizedInput: RendererBridgeInput) {
        self.authorizedInput = authorizedInput
        inputByteCount = { try store.rendererInputByteCount($0) }
        readPayload = { try Self.readPinnedPayload(from: store, input: $0) }
    }

    init(
        authorizedInput: RendererBridgeInput,
        inputByteCount: @escaping (RendererBridgeInput) throws -> Int?,
        readPayload: @escaping (RendererBridgeInput) throws -> RendererBridgeInputPayload
    ) {
        self.authorizedInput = authorizedInput
        self.inputByteCount = inputByteCount
        self.readPayload = readPayload
    }

    public func read(_ requestedInput: RendererBridgeInput) throws -> RendererBridgeInputPayload {
        guard requestedInput == authorizedInput else {
            throw RendererBridgeAuthorizationError.unauthorizedInput
        }
        guard let byteCount = try inputByteCount(requestedInput) else {
            throw RendererBridgeAuthorizationError.unavailablePinnedInput
        }
        guard byteCount >= 0,
              byteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        else {
            throw RendererBridgeAuthorizationError.oversizedPayload
        }
        return try payload(readPayload(requestedInput))
    }

    private static func readPinnedPayload(
        from store: any WikiStore,
        input requestedInput: RendererBridgeInput
    ) throws -> RendererBridgeInputPayload {
        switch requestedInput {
        case .source(let versionID):
            guard let version = try store.sourceVersion(id: versionID) else {
                throw RendererBridgeAuthorizationError.unavailablePinnedInput
            }
            let bytes: Data
            do {
                bytes = try store.sourceContent(versionID: versionID)
            } catch {
                throw RendererBridgeAuthorizationError.unavailablePinnedInput
            }
            return .init(mimeType: version.mimeType ?? "application/octet-stream", bytes: bytes)
        case .markdown(let versionID):
            guard let version = try store.processedMarkdownVersion(id: versionID) else {
                throw RendererBridgeAuthorizationError.unavailablePinnedInput
            }
            return .init(mimeType: version.mimeType, bytes: Data(version.content.utf8))
        }
    }

    private func payload(_ payload: RendererBridgeInputPayload) throws -> RendererBridgeInputPayload {
        guard payload.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount else {
            throw RendererBridgeAuthorizationError.oversizedPayload
        }
        return payload
    }
}
