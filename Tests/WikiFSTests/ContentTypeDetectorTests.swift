import Foundation
import Testing
@testable import WikiFSCore

struct ContentTypeDetectorTests {
    struct SignatureCase: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: Data
        let mimeType: String
        var testDescription: String { name }
    }

    static let signatures: [SignatureCase] = [
        .init(name: "PDF", bytes: Data("%PDF-1.7".utf8), mimeType: "application/pdf"),
        .init(name: "PNG", bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), mimeType: "image/png"),
        .init(name: "JPEG", bytes: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg"),
        .init(name: "GIF87a", bytes: Data("GIF87a".utf8), mimeType: "image/gif"),
        .init(name: "GIF89a", bytes: Data("GIF89a".utf8), mimeType: "image/gif"),
        .init(name: "WebP", bytes: Data("RIFF0000WEBP".utf8), mimeType: "image/webp"),
        .init(name: "ZIP local", bytes: Data([0x50, 0x4B, 0x03, 0x04]), mimeType: "application/zip"),
        .init(name: "ZIP empty", bytes: Data([0x50, 0x4B, 0x05, 0x06]), mimeType: "application/zip"),
        .init(name: "ZIP spanned", bytes: Data([0x50, 0x4B, 0x07, 0x08]), mimeType: "application/zip"),
        .init(name: "gzip", bytes: Data([0x1F, 0x8B]), mimeType: "application/gzip"),
        .init(name: "7z", bytes: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]), mimeType: "application/x-7z-compressed"),
        .init(name: "RAR v4", bytes: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]), mimeType: "application/vnd.rar"),
        .init(name: "RAR v5", bytes: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]), mimeType: "application/vnd.rar"),
    ]

    @Test func normalizesDeclaredMIMEParametersAndCase() {
        #expect(ContentTypeDetector.normalizeMIMEType("  APPLICATION/JSON; charset=UTF-8 ") == "application/json")
        #expect(ContentTypeDetector.normalizeMIMEType("not a mime") == nil)
        #expect(ContentTypeDetector.normalizeMIMEType("text/") == nil)
        #expect(ContentTypeDetector.normalizeMIMEType(nil) == nil)
    }

    @Test(arguments: signatures)
    func commonBinaryAndArchiveSignatures(_ value: SignatureCase) {
        let result = ContentTypeDetector.detect(.init(data: value.bytes))
        #expect(result.normalizedMIMEType == value.mimeType)
        #expect(result.confidence == .high)
        #expect(result.evidence.first?.origin == .binarySignature)
    }

    // MARK: - Registration-driven recognition (a .docx IS a zip)

    /// Recognition of registered zip-container inputs is NOT a detector
    /// concern: the byte sniffer stays pure and reports `application/zip`.
    /// The active extractor registrations' declared input surface promotes
    /// the type at the classification, dispatch, and store seams (tests in
    /// ContentTypeRegistryTests / FormatMaterializer / DocxExtractionService).
    @Test("zip bytes stay application/zip at the detector, whatever the name")
    func zipSniffIsRegistrationAgnostic() {
        let docxBytes = Data([0x50, 0x4B, 0x03, 0x04]) + Data("container".utf8)
        let noHints = ContentTypeDetector.detect(.init(data: docxBytes))
        #expect(noHints.normalizedMIMEType == MimeType.zip)

        let docxExt = ContentTypeDetector.detect(.init(
            data: docxBytes, hints: .init(filenameExtension: "docx")))
        #expect(docxExt.normalizedMIMEType == MimeType.zip)
    }

    @Test(arguments: signatures)
    func commonSignaturesRejectTruncatedInputs(_ value: SignatureCase) {
        let truncated = Data(value.bytes.prefix(1))
        let result = ContentTypeDetector.detect(.init(data: truncated))
        #expect(!result.evidence.contains { $0.origin == .binarySignature })
        #expect(result.normalizedMIMEType != value.mimeType)
    }

    @Test(arguments: signatures)
    func commonSignaturesRejectNearMisses(_ value: SignatureCase) {
        var nearMiss = value.bytes
        nearMiss[nearMiss.startIndex] ^= 0xFF
        let result = ContentTypeDetector.detect(.init(data: nearMiss))
        #expect(!result.evidence.contains { $0.origin == .binarySignature })
        #expect(result.normalizedMIMEType != value.mimeType)
    }

    @Test(arguments: signatures)
    func commonSignaturesOverrideConflictingHints(_ value: SignatureCase) {
        let result = ContentTypeDetector.detect(.init(
            data: value.bytes,
            hints: .init(
                declaredMIME: .init("text/plain", origin: .httpResponse),
                filenameExtension: "txt")))
        #expect(result.normalizedMIMEType == value.mimeType)
        #expect(result.conflicts.contains { $0.conflictingEvidence.origin == .httpResponse })
    }

    @Test func conflictingHintsRetainEvidenceAndConflictOrigins() {
        for origin in [DeclaredMIMEOrigin.httpResponse, .zoteroMetadata] {
            let result = ContentTypeDetector.detect(.init(
                data: Data("%PDF-1.7".utf8),
                hints: .init(
                    declaredMIME: .init("text/plain", origin: origin),
                    filenameExtension: "txt",
                    utiMIME: "text/plain")))
            #expect(result.normalizedMIMEType == "application/pdf")
            #expect(result.conflicts.map(\.conflictingEvidence.origin) == [
                .utf8Text,
                origin == .httpResponse ? .httpResponse : .zoteroMetadata,
                .uti,
                .filenameExtension,
            ])
        }
    }

    @Test func binarySignatureOverridesDeclaredHTTPMIME() {
        let result = ContentTypeDetector.detect(.init(
            data: Data("%PDF-1.7".utf8),
            hints: .init(
                declaredMIME: .init("text/plain", origin: .httpResponse),
                filenameExtension: "txt")))
        #expect(result.normalizedMIMEType == "application/pdf")
        #expect(result.conflicts.count == 3)
        #expect(result.conflicts.allSatisfy { $0.chosenMIMEType == "application/pdf" })
    }

    @Test func binarySignatureOverridesLocalUTIAndExtension() {
        let result = ContentTypeDetector.detect(.init(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            hints: .init(filenameExtension: "txt", utiMIME: "text/plain")))
        #expect(result.normalizedMIMEType == "image/png")
        #expect(result.conflicts.map(\.conflictingEvidence.origin) == [.uti, .filenameExtension])
    }

    @Test func detectsJSONSVGXMLHTMLAndText() {
        let values: [(Data, String)] = [
            (Data("{\"value\":1}".utf8), "application/json"),
            (Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8), "image/svg+xml"),
            (Data("<?xml version=\"1.0\"?><root/>".utf8), "application/xml"),
            (Data("<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><body><svg></svg></body></html>".utf8), MimeType.xhtml),
            (Data("<!doctype html><html></html>".utf8), "text/html"),
            (Data("plain UTF-8 text".utf8), "text/plain"),
        ]
        for (data, expected) in values {
            #expect(ContentTypeDetector.detect(.init(data: data)).normalizedMIMEType == expected)
        }
    }

    @Test func xhtmlStructureOverridesConflictingDeclaration() {
        let data = Data(
            "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"></html>".utf8)
        let result = ContentTypeDetector.detect(.init(
            data: data,
            hints: ContentTypeDetectionHints(
                declaredMIME: DeclaredMIME("application/xml", origin: .httpResponse))))

        #expect(result.normalizedMIMEType == MimeType.xhtml)
        #expect(result.conflicts.contains { $0.conflictingEvidence.mimeType == "application/xml" })
    }

    @Test func unknownBinaryIsInconclusive() {
        let result = ContentTypeDetector.detect(.init(data: Data([0x00, 0xFF, 0x00, 0x81])))
        #expect(result.normalizedMIMEType == nil)
        #expect(result.confidence == nil)
    }

    @Test func syntacticallyValidStructuredPrefixMarkedTruncatedIsInconclusive() {
        let prefix = BoundedContentPrefix(bytes: Data("{\"nodes\":[],\"edges\":[]}".utf8), completeness: .truncated)
        let result = ContentTypeDetector.detect(.init(prefix: prefix))
        #expect(result.normalizedMIMEType == nil)
        #expect(result.structuredArtifactKind == nil)
    }

    @Test func truncatedStructuredInputCanUseCompatibleDeclaration() {
        let prefix = BoundedContentPrefix(bytes: Data("{\"value\":1}".utf8), completeness: .truncated)
        let result = ContentTypeDetector.detect(.init(
            hints: .init(declaredMIME: .init("application/json", origin: .httpResponse)),
            prefix: prefix))
        #expect(result.normalizedMIMEType == "application/json")
        #expect(result.structuredArtifactKind == nil)
    }

    @Test func validJSONCanvasProducesJSONAndArtifact() {
        let result = ContentTypeDetector.detect(.init(data: Data("{\"nodes\":[],\"edges\":[]}".utf8)))
        #expect(result.normalizedMIMEType == "application/json")
        #expect(result.structuredArtifactKind == .jsonCanvas)
    }

    @Test func malformedOrGenericJSONHasNoArtifact() {
        let generic = ContentTypeDetector.detect(.init(data: Data("{\"value\":1}".utf8)))
        let malformed = ContentTypeDetector.detect(.init(data: Data("{\"nodes\":[}".utf8)))
        #expect(generic.normalizedMIMEType == "application/json")
        #expect(generic.structuredArtifactKind == nil)
        #expect(malformed.structuredArtifactKind == nil)
    }

    @Test func neverExaminesPastMaximumPrefix() {
        var data = Data(repeating: 0, count: ContentTypeDetectionLimits.maximumPrefixByteCount)
        data.append(Data("%PDF-".utf8))
        let result = ContentTypeDetector.detect(.init(data: data))
        #expect(result.normalizedMIMEType == nil)
    }
}
