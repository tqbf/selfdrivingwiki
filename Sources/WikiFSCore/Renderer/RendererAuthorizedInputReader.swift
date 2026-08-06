import Foundation

// pattern: Imperative Shell

/// Reads only the immutable input version pinned when a renderer session began.
/// This intentionally has no SourceID-based API, which prevents an accidental
/// call to the live-ref `WikiStore.sourceContent(id:)` path.
public struct RendererAuthorizedInputReader {
    private let store: any WikiStore
    public let authorizedInput: RendererBridgeInput

    public init(store: any WikiStore, authorizedInput: RendererBridgeInput) {
        self.store = store
        self.authorizedInput = authorizedInput
    }

    public func read(_ requestedInput: RendererBridgeInput) throws -> RendererBridgeInputPayload {
        guard requestedInput == authorizedInput else {
            throw RendererBridgeAuthorizationError.unauthorizedInput
        }
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
            return try payload(mimeType: version.mimeType ?? "application/octet-stream", bytes: bytes)
        case .markdown(let versionID):
            guard let version = try store.processedMarkdownVersion(id: versionID) else {
                throw RendererBridgeAuthorizationError.unavailablePinnedInput
            }
            return try payload(mimeType: version.mimeType, bytes: Data(version.content.utf8))
        }
    }

    private func payload(mimeType: String, bytes: Data) throws -> RendererBridgeInputPayload {
        guard bytes.count <= WikiAppWebViewPolicy.maximumSourceByteCount else {
            throw RendererBridgeAuthorizationError.oversizedPayload
        }
        return RendererBridgeInputPayload(mimeType: mimeType, bytes: bytes)
    }
}
