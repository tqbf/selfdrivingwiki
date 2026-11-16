import Foundation
import Synchronization

// pattern: Imperative Shell

/// Reads only the immutable input version pinned when a renderer session began.
/// This intentionally has no SourceID-based API, which prevents an accidental
/// call to the live-ref `WikiStore.sourceContent(id:)` path.
@MainActor
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

    private let inputByteCount: (RendererBridgeInput) async throws -> Int?
    private let readPayload: (RendererBridgeInput) async throws -> RendererBridgeInputPayload
    private let state: Mutex<State>
    public let authorizedInput: RendererBridgeInput

    public init(store: any WikiStore, authorizedInput: RendererBridgeInput) {
        self.authorizedInput = authorizedInput
        inputByteCount = { try await store.rendererInputByteCount($0) }
        readPayload = { try await Self.readPinnedPayload(from: store, input: $0) }
        state = Mutex(State())
    }

    public init(
        store: any WikiStore,
        authorizedInput: RendererBridgeInput,
        admittedSource: RendererEmbeddedContent.Source
    ) throws {
        guard Self.matchesVersion(admittedSource, input: authorizedInput) else {
            throw ReaderError.unauthorizedInput
        }
        self.authorizedInput = authorizedInput
        inputByteCount = { requestedInput in
            guard requestedInput == authorizedInput else { throw ReaderError.unauthorizedInput }
            return admittedSource.bytes.count
        }
        readPayload = { requestedInput in
            guard requestedInput == authorizedInput else { throw ReaderError.unauthorizedInput }
            let payload = try await Self.readPinnedPayload(from: store, input: requestedInput)
            guard payload.mimeType == admittedSource.mimeType.rawValue,
                  payload.bytes == admittedSource.bytes,
                  RendererSHA256.digest(payload.bytes) == admittedSource.digest else {
                throw ReaderError.unavailablePinnedInput
            }
            return payload
        }
        state = Mutex(State())
    }

    init(
        authorizedInput: RendererBridgeInput,
        inputByteCount: @escaping (RendererBridgeInput) async throws -> Int?,
        readPayload: @escaping (RendererBridgeInput) async throws -> RendererBridgeInputPayload
    ) {
        self.authorizedInput = authorizedInput
        self.inputByteCount = inputByteCount
        self.readPayload = readPayload
        state = Mutex(State())
    }

    public func read(_ requestedInput: RendererBridgeInput) async throws -> RendererBridgeInputPayload {
        try validateOpen()
        guard requestedInput == authorizedInput else {
            // Encoding for the mismatch log cannot fail for these Codable
            // values; a failure would indicate a contract bug worth surfacing
            // via the mismatch message itself.
            func encodeForLog(_ value: RendererBridgeInput) -> String {
                do {
                    return String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "?"
                } catch {
                    return "encode-error: \(error)"
                }
            }
            DebugLog.reader("reader input mismatch: requested[\(encodeForLog(requestedInput).prefix(160))] authorized[\(encodeForLog(authorizedInput).prefix(160))]")
            throw ReaderError.unauthorizedInput
        }
        try await validateInput(
            maximumInputByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
            maximumDecodedByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        )
        return try payload(
            try await readPayload(requestedInput),
            maximumDecodedByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        )
    }

    /// Checks that the pinned input is still available and fits both the
    /// descriptor and bridge limits before a WebKit session is created.
    public func validateInput(maximumByteCount: Int) async throws {
        try await validateInput(
            maximumInputByteCount: maximumByteCount,
            maximumDecodedByteCount: WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
        )
    }

    public func validateInput(maximumInputByteCount: Int, maximumDecodedByteCount: Int) async throws {
        try validateOpen()
        guard maximumInputByteCount > 0, maximumDecodedByteCount > 0 else {
            throw ReaderError.oversizedInput
        }
        guard maximumDecodedByteCount >= maximumInputByteCount else {
            throw ReaderError.oversizedInput
        }
        guard let byteCount = try await inputByteCount(authorizedInput) else {
            throw ReaderError.unavailablePinnedInput
        }
        guard byteCount >= 0, byteCount <= maximumInputByteCount else {
            throw ReaderError.oversizedInput
        }
    }

    private static func matchesVersion(
        _ source: RendererEmbeddedContent.Source,
        input: RendererBridgeInput
    ) -> Bool {
        switch input {
        case .source(let versionID):
            return source.sourceVersionID == versionID && source.sourceMarkdownVersionID == nil
        case .markdown(let versionID):
            return source.sourceVersionID == nil && source.sourceMarkdownVersionID == versionID
        case .inlineArtifact:
            return false
        }
    }

    private static func readPinnedPayload(
        from store: any WikiStore,
        input requestedInput: RendererBridgeInput
    ) async throws -> RendererBridgeInputPayload {
        switch requestedInput {
        case .source(let versionID):
            guard let version = try await store.sourceVersion(id: versionID) else {
                throw ReaderError.unavailablePinnedInput
            }
            let bytes: Data
            do {
                bytes = try await store.sourceContent(versionID: versionID)
            } catch {
                throw ReaderError.unavailablePinnedInput
            }
            return .init(mimeType: version.mimeType ?? "application/octet-stream", bytes: bytes)
        case .markdown(let versionID):
            guard let version = try await store.processedMarkdownVersion(id: versionID) else {
                throw ReaderError.unavailablePinnedInput
            }
            return .init(mimeType: version.mimeType, bytes: Data(version.content.utf8))
        case .inlineArtifact(let artifact):
            let digest = RendererSHA256.digest(artifact.canonicalDigestPayload)
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
