import Foundation
import Synchronization

// pattern: Imperative Shell

/// Reads only the immutable input version pinned when a renderer session began.
/// This intentionally has no SourceID-based API, which prevents an accidental
/// call to the live-ref `WikiStore.sourceContent(id:)` path.
public final class RendererAuthorizedInputReader {
    public enum ReaderError: Error, Equatable, Sendable {
        case closed
        case unauthorizedInput
        case unavailablePinnedInput
        case oversizedInput
        case oversizedPayload
    }

    private struct State: Sendable {
        var isClosed: Bool = false
    }

    private let inputByteCount: (RendererBridgeInput) throws -> Int?
    private let readPayload: (RendererBridgeInput) throws -> RendererBridgeInputPayload
    private let state: Mutex<State>
    public let authorizedInput: RendererBridgeInput

    public init(store: any WikiStore, authorizedInput: RendererBridgeInput) {
        self.authorizedInput = authorizedInput
        inputByteCount = { try store.rendererInputByteCount($0) }
        readPayload = { try Self.readPinnedPayload(from: store, input: $0) }
        state = Mutex(State())
    }

    init(
        authorizedInput: RendererBridgeInput,
        inputByteCount: @escaping (RendererBridgeInput) throws -> Int?,
        readPayload: @escaping (RendererBridgeInput) throws -> RendererBridgeInputPayload
    ) {
        self.authorizedInput = authorizedInput
        self.inputByteCount = inputByteCount
        self.readPayload = readPayload
        state = Mutex(State())
    }

    public func read(_ requestedInput: RendererBridgeInput) throws -> RendererBridgeInputPayload {
        try validateOpen()
        guard requestedInput == authorizedInput else {
            throw ReaderError.unauthorizedInput
        }
        try validateInput(
            maximumInputByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
            maximumDecodedByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        )
        return try payload(
            readPayload(requestedInput),
            maximumDecodedByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        )
    }

    /// Checks that the pinned input is still available and fits both the
    /// descriptor and bridge limits before a WebKit session is created.
    public func validateInput(maximumByteCount: Int) throws {
        try validateInput(
            maximumInputByteCount: maximumByteCount,
            maximumDecodedByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        )
    }

    public func validateInput(maximumInputByteCount: Int, maximumDecodedByteCount: Int) throws {
        try validateOpen()
        guard maximumInputByteCount > 0, maximumDecodedByteCount > 0 else {
            throw ReaderError.oversizedInput
        }
        guard maximumDecodedByteCount >= maximumInputByteCount else {
            throw ReaderError.oversizedInput
        }
        guard let byteCount = try inputByteCount(authorizedInput) else {
            throw ReaderError.unavailablePinnedInput
        }
        guard byteCount >= 0, byteCount <= maximumInputByteCount else {
            throw ReaderError.oversizedInput
        }
    }

    private static func readPinnedPayload(
        from store: any WikiStore,
        input requestedInput: RendererBridgeInput
    ) throws -> RendererBridgeInputPayload {
        switch requestedInput {
        case .source(let versionID):
            guard let version = try store.sourceVersion(id: versionID) else {
                throw ReaderError.unavailablePinnedInput
            }
            let bytes: Data
            do {
                bytes = try store.sourceContent(versionID: versionID)
            } catch {
                throw ReaderError.unavailablePinnedInput
            }
            return .init(mimeType: version.mimeType ?? "application/octet-stream", bytes: bytes)
        case .markdown(let versionID):
            guard let version = try store.processedMarkdownVersion(id: versionID) else {
                throw ReaderError.unavailablePinnedInput
            }
            return .init(mimeType: version.mimeType, bytes: Data(version.content.utf8))
        case .inlineArtifact(let artifact):
            let digest = RendererSHA256.digest(artifact.bytes)
            guard digest == artifact.digest else {
                throw ReaderError.unavailablePinnedInput
            }
            return .init(mimeType: artifact.mimeType.rawValue, bytes: artifact.bytes)
        }
    }

    private func payload(
        _ payload: RendererBridgeInputPayload,
        maximumDecodedByteCount: Int
    ) throws -> RendererBridgeInputPayload {
        guard payload.bytes.count <= maximumDecodedByteCount else {
            throw ReaderError.oversizedPayload
        }
        return payload
    }

    public func close() {
        state.withLock { value in
            value.isClosed = true
        }
    }

    private func validateOpen() throws {
        let closed = state.withLock { $0.isClosed }
        guard closed == false else { throw ReaderError.closed }
    }
}
