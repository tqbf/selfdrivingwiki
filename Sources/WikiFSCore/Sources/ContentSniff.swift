import Foundation

public enum ContentTypeDetectionLimits {
    /// The maximum byte count that generic content detection can inspect.
    public static let maximumPrefixByteCount = 64 * 1_024
}

public enum ContentPrefixCompleteness: String, Codable, Hashable, Sendable {
    case complete
    case truncated
}

/// A byte prefix whose completeness is explicit and never inferred from its size.
public struct BoundedContentPrefix: Codable, Hashable, Sendable {
    public let bytes: Data
    public let completeness: ContentPrefixCompleteness

    public init(bytes: Data, completeness: ContentPrefixCompleteness) {
        let bounded = Data(bytes.prefix(ContentTypeDetectionLimits.maximumPrefixByteCount))
        self.bytes = bounded
        self.completeness = bytes.count > ContentTypeDetectionLimits.maximumPrefixByteCount ? .truncated : completeness
    }

    public init(data: Data) {
        let limit = ContentTypeDetectionLimits.maximumPrefixByteCount
        bytes = Data(data.prefix(limit))
        completeness = data.count <= limit ? .complete : .truncated
    }
}

public enum DeclaredMIMEOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case httpResponse
    case zoteroMetadata
    case localUTI
    case trustedGenerated
}

public struct DeclaredMIME: Codable, Hashable, Sendable {
    public let value: String
    public let origin: DeclaredMIMEOrigin

    public init(_ value: String, origin: DeclaredMIMEOrigin) {
        self.value = value
        self.origin = origin
    }
}

public struct ContentTypeDetectionHints: Codable, Hashable, Sendable {
    public let declaredMIME: DeclaredMIME?
    public let filenameExtension: String?
    public let utiMIME: String?

    public init(declaredMIME: DeclaredMIME? = nil, filenameExtension: String? = nil, utiMIME: String? = nil) {
        self.declaredMIME = declaredMIME
        self.filenameExtension = filenameExtension
        self.utiMIME = utiMIME
    }

    public init(declaredMIME: DeclaredMIME? = nil, filename: String, utiMIME: String? = nil) {
        let ext = (filename as NSString).pathExtension
        self.init(declaredMIME: declaredMIME, filenameExtension: ext.isEmpty ? nil : ext, utiMIME: utiMIME)
    }
}

public struct ContentTypeDetectionInput: Hashable, Sendable {
    public let hints: ContentTypeDetectionHints
    public let prefix: BoundedContentPrefix

    public init(hints: ContentTypeDetectionHints = .init(), prefix: BoundedContentPrefix) {
        self.hints = hints
        self.prefix = prefix
    }

    public init(data: Data, hints: ContentTypeDetectionHints = .init()) {
        self.init(hints: hints, prefix: BoundedContentPrefix(data: data))
    }
}

public enum ContentTypeEvidenceOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case binarySignature
    case structuredBytes
    case utf8Text
    case httpResponse
    case zoteroMetadata
    case trustedGenerated
    case uti
    case filenameExtension
}

public enum ContentTypeConfidence: Int, Codable, Comparable, Hashable, Sendable {
    case fallback = 10
    case declared = 20
    case probable = 30
    case high = 40

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ContentTypeEvidence: Codable, Hashable, Sendable {
    public let origin: ContentTypeEvidenceOrigin
    public let mimeType: String
    public let confidence: ContentTypeConfidence
    public let detail: String?

    public init(origin: ContentTypeEvidenceOrigin, mimeType: String, confidence: ContentTypeConfidence, detail: String? = nil) {
        self.origin = origin
        self.mimeType = mimeType
        self.confidence = confidence
        self.detail = detail
    }
}

public enum ContentTypeConflictKind: String, Codable, Hashable, Sendable {
    case disagreement
    case trustedGeneratedMismatch
}

public struct ContentTypeConflict: Codable, Hashable, Sendable {
    public let kind: ContentTypeConflictKind
    public let chosenMIMEType: String
    public let conflictingEvidence: ContentTypeEvidence
}

public struct ContentTypeDetectionResult: Codable, Hashable, Sendable {
    public let normalizedMIMEType: String?
    public let evidence: [ContentTypeEvidence]
    public let confidence: ContentTypeConfidence?
    public let conflicts: [ContentTypeConflict]
    public let structuredArtifactKind: ContentArtifactKind?

    public init(
        normalizedMIMEType: String?,
        evidence: [ContentTypeEvidence],
        confidence: ContentTypeConfidence?,
        conflicts: [ContentTypeConflict],
        structuredArtifactKind: ContentArtifactKind?
    ) {
        self.normalizedMIMEType = normalizedMIMEType
        self.evidence = evidence
        self.confidence = confidence
        self.conflicts = conflicts
        self.structuredArtifactKind = structuredArtifactKind
    }
}

/// Pure bounded content-type detection. Byte evidence has authority over metadata hints.
public enum ContentTypeDetector {
    private struct Signature {
        let offset: Int
        let bytes: [UInt8]
        let mimeType: String
        let name: String
    }

    private static let signatures: [Signature] = [
        .init(offset: 0, bytes: Array("%PDF-".utf8), mimeType: MimeType.pdf, name: "PDF"),
        .init(offset: 0, bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], mimeType: "image/png", name: "PNG"),
        .init(offset: 0, bytes: [0xFF, 0xD8, 0xFF], mimeType: "image/jpeg", name: "JPEG"),
        .init(offset: 0, bytes: Array("GIF87a".utf8), mimeType: "image/gif", name: "GIF87a"),
        .init(offset: 0, bytes: Array("GIF89a".utf8), mimeType: "image/gif", name: "GIF89a"),
        .init(offset: 0, bytes: [0x50, 0x4B, 0x03, 0x04], mimeType: "application/zip", name: "ZIP local"),
        .init(offset: 0, bytes: [0x50, 0x4B, 0x05, 0x06], mimeType: "application/zip", name: "ZIP empty"),
        .init(offset: 0, bytes: [0x50, 0x4B, 0x07, 0x08], mimeType: "application/zip", name: "ZIP spanned"),
        .init(offset: 0, bytes: [0x1F, 0x8B], mimeType: "application/gzip", name: "gzip"),
        .init(offset: 0, bytes: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], mimeType: "application/x-7z-compressed", name: "7z"),
        .init(offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00], mimeType: "application/vnd.rar", name: "RAR v4"),
        .init(offset: 0, bytes: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], mimeType: "application/vnd.rar", name: "RAR v5"),
        .init(offset: 0, bytes: Array("RIFF".utf8), mimeType: "image/webp", name: "WebP RIFF"),
    ]

    public static func normalizeMIMEType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let value = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 127 else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        guard value.unicodeScalars.allSatisfy({ $0 == "/" || allowed.contains($0) }) else { return nil }
        return value
    }

    public static func detect(_ input: ContentTypeDetectionInput) -> ContentTypeDetectionResult {
        let bytes = input.prefix.bytes
        var evidence: [ContentTypeEvidence] = []

        if let binary = binaryEvidence(bytes) { evidence.append(binary) }
        if input.prefix.completeness == .complete, let structured = structuredEvidence(bytes) {
            evidence.append(structured)
        }
        if input.prefix.completeness == .complete, isPlausibleUTF8Text(bytes) {
            evidence.append(.init(origin: .utf8Text, mimeType: "text/plain", confidence: .probable))
        }
        if let declared = input.hints.declaredMIME,
           let mime = normalizeMIMEType(declared.value) {
            evidence.append(.init(
                origin: evidenceOrigin(for: declared.origin),
                mimeType: mime,
                confidence: declared.origin == .trustedGenerated ? .high : .declared))
        }
        if let mime = normalizeMIMEType(input.hints.utiMIME) {
            evidence.append(.init(origin: .uti, mimeType: mime, confidence: .fallback))
        }
        if let ext = normalizedExtension(input.hints.filenameExtension),
           let mime = extensionMIME(ext) {
            evidence.append(.init(origin: .filenameExtension, mimeType: mime, confidence: .fallback, detail: ext))
        }

        let chosen = chooseEvidence(evidence, prefix: input.prefix)
        let artifact: ContentArtifactKind? = ContentArtifactValidator.matches(
            .jsonCanvas,
            input: BoundedArtifactInput(
                bytes: Data(bytes.prefix(ContentArtifactValidationLimits.maximumInputByteCount)),
                isComplete: input.prefix.completeness == .complete && bytes.count <= ContentArtifactValidationLimits.maximumInputByteCount))
            ? .jsonCanvas : nil
        let conflicts = chosen.map { selected in
            evidence.compactMap { item -> ContentTypeConflict? in
                guard item.mimeType != selected.mimeType else { return nil }
                let kind: ContentTypeConflictKind = item.origin == .trustedGenerated && selected.origin == .binarySignature
                    ? .trustedGeneratedMismatch : .disagreement
                return .init(kind: kind, chosenMIMEType: selected.mimeType, conflictingEvidence: item)
            }
        } ?? []
        return .init(
            normalizedMIMEType: chosen?.mimeType,
            evidence: evidence,
            confidence: chosen?.confidence,
            conflicts: conflicts,
            structuredArtifactKind: artifact)
    }

    private static func chooseEvidence(_ evidence: [ContentTypeEvidence], prefix: BoundedContentPrefix) -> ContentTypeEvidence? {
        if let signature = evidence.first(where: { $0.origin == .binarySignature }) { return signature }
        if let structured = evidence.first(where: { $0.origin == .structuredBytes }) { return structured }
        if let trusted = evidence.first(where: { $0.origin == .trustedGenerated }) { return trusted }
        if let declared = evidence.first(where: { [.httpResponse, .zoteroMetadata].contains($0.origin) }),
           declared.mimeType != MimeType.octetStream {
            return declared
        }
        if let text = evidence.first(where: { $0.origin == .utf8Text }) {
            let specificText = evidence.first { $0.mimeType.hasPrefix("text/") && $0.origin != .utf8Text }
            return specificText ?? text
        }
        if prefix.completeness == .truncated,
           let declared = evidence.first(where: { [.httpResponse, .zoteroMetadata].contains($0.origin) }),
           declared.mimeType != MimeType.octetStream {
            return declared
        }
        return evidence.first(where: { [.uti, .filenameExtension].contains($0.origin) && $0.mimeType != MimeType.octetStream })
    }

    private static func binaryEvidence(_ data: Data) -> ContentTypeEvidence? {
        let bytes = [UInt8](data)
        for signature in signatures {
            let end = signature.offset + signature.bytes.count
            guard bytes.count >= end else { continue }
            guard Array(bytes[signature.offset..<end]) == signature.bytes else { continue }
            if signature.name == "WebP RIFF" {
                guard bytes.count >= 12, Array(bytes[8..<12]) == Array("WEBP".utf8) else { continue }
            }
            return .init(origin: .binarySignature, mimeType: signature.mimeType, confidence: .high, detail: signature.name)
        }
        return nil
    }

    private static func structuredEvidence(_ data: Data) -> ContentTypeEvidence? {
        guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if (trimmed.first == "{" || trimmed.first == "[") && isValidJSON(data) {
            return .init(origin: .structuredBytes, mimeType: "application/json", confidence: .high, detail: "JSON")
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
            return .init(origin: .structuredBytes, mimeType: MimeType.html, confidence: .high, detail: "HTML")
        }
        if lower.hasPrefix("<?xml") && lower.contains("<html") {
            return .init(origin: .structuredBytes, mimeType: MimeType.xhtml, confidence: .high, detail: "XHTML")
        }
        if lower.hasPrefix("<svg") || (lower.hasPrefix("<?xml") && lower.contains("<svg")) {
            return .init(origin: .structuredBytes, mimeType: "image/svg+xml", confidence: .high, detail: "SVG")
        }
        if lower.hasPrefix("<?xml") {
            return .init(origin: .structuredBytes, mimeType: "application/xml", confidence: .high, detail: "XML")
        }
        return nil
    }

    private static func isValidJSON(_ data: Data) -> Bool {
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            // Malformed input is an expected negative detection result.
            return false
        }
    }

    private static func isPlausibleUTF8Text(_ data: Data) -> Bool {
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { return false }
        return !data.contains(0)
    }

    private static func evidenceOrigin(for origin: DeclaredMIMEOrigin) -> ContentTypeEvidenceOrigin {
        switch origin {
        case .httpResponse: .httpResponse
        case .zoteroMetadata: .zoteroMetadata
        case .localUTI: .uti
        case .trustedGenerated: .trustedGenerated
        }
    }

    private static func normalizedExtension(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)).lowercased()
        return value?.isEmpty == false ? value : nil
    }

    private static func extensionMIME(_ ext: String) -> String? {
        if let projectMIME = MimeType.mime(forExtension: ext) { return projectMIME }
        switch ext {
        case "txt": return "text/plain"
        case "html", "htm": return MimeType.html
        case "xhtml": return MimeType.xhtml
        case "json", "canvas": return "application/json"
        case "xml": return "application/xml"
        case "svg": return "image/svg+xml"
        case "pdf": return MimeType.pdf
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "zip": return "application/zip"
        case "gz", "gzip": return "application/gzip"
        case "7z": return "application/x-7z-compressed"
        case "rar": return "application/vnd.rar"
        default: return nil
        }
    }
}
