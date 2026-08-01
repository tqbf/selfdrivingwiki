import Foundation

// pattern: Functional Core

public struct RendererSignature: Codable, Hashable, Sendable {
    public let offset: Int
    public let bytes: [UInt8]

    public init(offset: Int, bytes: [UInt8]) throws {
        guard offset >= 0, bytes.isEmpty == false,
              offset <= RendererMatchingLimits.maximumSniffByteCount,
              bytes.count <= RendererMatchingLimits.maximumSniffByteCount - offset else {
            throw RendererValidationError.invalidSignature
        }
        self.offset = offset
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(offset: container.decode(Int.self, forKey: .offset), bytes: container.decode([UInt8].self, forKey: .bytes))
    }
}

public enum RendererMatcher: Codable, Hashable, Sendable {
    case normalizedMIME(RendererMIMEType)
    case extensionFallback(RendererFileExtension)
    case boundedSignature(RendererSignature)
    case artifactKind(RendererArtifactKind)

    public func matches(_ input: RendererMatchInput) -> Bool {
        switch self {
        case let .normalizedMIME(mime): input.mimeType == mime
        case let .extensionFallback(fileExtension): input.fileExtension == fileExtension
        case let .boundedSignature(signature): input.sniffedBytes.matches(signature)
        case let .artifactKind(kind): input.artifactKind == kind
        }
    }

    public var isExtensionFallback: Bool {
        if case .extensionFallback = self { return true }
        return false
    }
}

public struct RendererMatchInput: Hashable, Sendable {
    public let mimeType: RendererMIMEType?
    public let fileExtension: RendererFileExtension?
    public let sniffedBytes: Data
    public let artifactKind: RendererArtifactKind?

    public init(mimeType: RendererMIMEType?, fileExtension: RendererFileExtension?, sniffedBytes: Data, artifactKind: RendererArtifactKind?) throws {
        guard sniffedBytes.count <= RendererMatchingLimits.maximumSniffByteCount else {
            throw RendererValidationError.invalidSizeLimit("sniff byte count \(sniffedBytes.count)")
        }
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.sniffedBytes = sniffedBytes
        self.artifactKind = artifactKind
    }
}

private extension Data {
    func matches(_ signature: RendererSignature) -> Bool {
        let end = signature.offset + signature.bytes.count
        guard count >= end else { return false }
        return Array(self[signature.offset..<end]) == signature.bytes
    }
}
