import Foundation

/// A structured content kind that byte ingestion and renderer matching can share.
public enum ContentArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case jsonCanvas
}

/// A bounded artifact-validation input. Callers state completeness explicitly.
public struct BoundedArtifactInput: Hashable, Sendable {
    public let bytes: Data
    public let isComplete: Bool

    public init(bytes: Data, isComplete: Bool) {
        self.bytes = Data(bytes.prefix(ContentArtifactValidationLimits.maximumInputByteCount))
        self.isComplete = isComplete && bytes.count <= ContentArtifactValidationLimits.maximumInputByteCount
    }
}

public enum ContentArtifactValidationLimits {
    public static let maximumInputByteCount = 64 * 1_024
}

/// Fail-closed structural validation for supported structured artifacts.
public enum ContentArtifactValidator {
    public static func matches(_ kind: ContentArtifactKind, input: BoundedArtifactInput) -> Bool {
        guard input.isComplete else { return false }
        switch kind {
        case .jsonCanvas:
            do {
                _ = try JSONDecoder().decode(JSONCanvasSignature.self, from: input.bytes)
                return true
            } catch {
                return false
            }
        }
    }
}

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
    /// A format discriminator decoded only from the bounded registry sniff.
    /// Descriptors that include one require it to match before MIME or filename
    /// routing may select the renderer.
    case boundedJSONArtifact(RendererJSONArtifact)
    case artifactKind(RendererArtifactKind)

    public func matches(_ input: RendererMatchInput) -> Bool {
        switch self {
        case let .normalizedMIME(mime): input.mimeType == mime
        case let .extensionFallback(fileExtension): input.fileExtension == fileExtension
        case let .boundedSignature(signature): input.sniffedBytes.matches(signature)
        case let .boundedJSONArtifact(artifact):
            artifact.matches(sniffedBytes: input.sniffedBytes, isComplete: input.sniffedBytesAreComplete)
        case let .artifactKind(kind): input.artifactKind == kind
        }
    }

    public var isExtensionFallback: Bool {
        if case .extensionFallback = self { return true }
        return false
    }

    /// JSON artifact validation is a required gate rather than an alternative
    /// routing hint. This preserves Source fallback for malformed files whose
    /// MIME type or extension otherwise looks renderable.
    public var requiresArtifactValidation: Bool {
        if case .boundedJSONArtifact = self { return true }
        return false
    }
}

/// The narrow JSON artifact signatures this phase can recognize. They are not
/// document models: full Excalidraw and JSON Canvas decoding follows in later
/// Phase 6 slices.
public enum RendererJSONArtifact: String, Codable, CaseIterable, Hashable, Sendable {
    case excalidraw
    case jsonCanvas

    /// Decodes no more than the established renderer sniff limit and rejects
    /// malformed or format-incomplete values. Callers with a larger byte body
    /// must first take the same bounded prefix used by ``RendererMatchInput``.
    public func matches(sniffedBytes: Data, isComplete: Bool = true) -> Bool {
        guard sniffedBytes.count <= RendererMatchingLimits.maximumSniffByteCount else {
            return false
        }

        switch self {
        case .excalidraw:
            do {
                let signature = try JSONDecoder().decode(ExcalidrawSignature.self, from: sniffedBytes)
                return signature.type == "excalidraw" && signature.version == ExcalidrawSignature.currentVersion
            } catch {
                // A malformed sniff is an expected non-match; Source remains available.
                return false
            }
        case .jsonCanvas:
            return ContentArtifactValidator.matches(
                .jsonCanvas,
                input: BoundedArtifactInput(bytes: sniffedBytes, isComplete: isComplete))
        }
    }
}

public struct RendererMatchInput: Hashable, Sendable {
    public let mimeType: RendererMIMEType?
    public let fileExtension: RendererFileExtension?
    public let sniffedBytes: Data
    public let sniffedBytesAreComplete: Bool
    public let artifactKind: RendererArtifactKind?

    public init(
        mimeType: RendererMIMEType?,
        fileExtension: RendererFileExtension?,
        sniffedBytes: Data,
        sniffedBytesAreComplete: Bool = true,
        artifactKind: RendererArtifactKind?
    ) throws {
        guard sniffedBytes.count <= RendererMatchingLimits.maximumSniffByteCount else {
            throw RendererValidationError.invalidSizeLimit("sniff byte count \(sniffedBytes.count)")
        }
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.sniffedBytes = sniffedBytes
        self.sniffedBytesAreComplete = sniffedBytesAreComplete
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

private struct ExcalidrawSignature: Decodable {
    static let currentVersion = 2

    let type: String
    let version: Int
    let elements: [JSONObject]
}

private struct JSONCanvasSignature: Decodable {
    let nodes: [JSONObject]
    let edges: [JSONObject]
}

/// Validates that the signature arrays contain JSON objects without allocating
/// an untyped tree. The entire decoder input is already capped at 4 KiB.
private struct JSONObject: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try decoder.container(keyedBy: JSONKey.self)
    }
}

private struct JSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
