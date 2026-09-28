import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSEngine

/// AC.3 — the revision-5 fetch-result contract at the pure-type edge.
///
/// Covers the frame-sequence validator's fetcher rules (explicit typed
/// result required; revision-5 fields rejected by older revisions), the
/// `ExtractorResultFrame` init rejections for contradictory tag/MIME
/// combinations, `ExtractorFetchRequest.validateFilename`, the process
/// fetcher's `interpretedOutcome` interpretation edge, and the tagged
/// request envelope's routing and unknown-key policy.
@Suite("Fetcher protocol result contract")
struct FetcherProtocolResultTests {

    // MARK: - Fixtures

    private static let requestID = ExtractorRequestID()
    private static let outputPath = try! ExtractorRelativePath(validating: "output/fetch/result")

    private static func pdfMIME() throws -> ExtractorMIMEType {
        try ExtractorMIMEType(validating: "application/pdf")
    }

    private static func markdownMIME() throws -> ExtractorMIMEType {
        try ExtractorMIMEType(validating: ExtractorResultFrame.markdownResultMIMERawValue)
    }

    private static func fetchSequence(
        protocolRevision: ExtractorProtocolRevision = .v5,
        isFetcherRequest: Bool = true
    ) -> ExtractorProtocolSequence {
        ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: outputPath,
            maximumProgressEventCount: 8,
            protocolRevision: protocolRevision,
            isFetcherRequest: isFetcherRequest)
    }

    @discardableResult
    private static func makeFrame(
        byteCount: Int = 3,
        resultType: ExtractorFetchResultType? = nil,
        resultMIMEType: ExtractorMIMEType? = nil,
        originalFilename: String? = nil,
        identifier: String? = nil
    ) throws -> ExtractorResultFrame {
        try ExtractorResultFrame(
            requestID: requestID,
            outputPath: outputPath,
            markdownByteCount: byteCount,
            metadata: ExtractorReportedMetadata(toolName: "zotero"),
            articleMetadata: try ExtractorArticleMetadata(
                title: "A Study of Extraction", identifier: identifier),
            resultMIMEType: resultMIMEType,
            resultType: resultType,
            originalFilename: originalFilename)
    }

    // MARK: - Sequence: the fetcher explicit-result contract

    @Test func fetcherResultWithoutTypeTagRejected() throws {
        var sequence = Self.fetchSequence()
        // A valid legacy-shaped markdown frame (no tag) is still a protocol
        // violation for a fetcher: the tag is required, never implied.
        let frame = try Self.makeFrame(resultType: nil, resultMIMEType: nil)
        #expect(throws: ExtractorProtocolSequenceError.fetcherResultTypeMissing) {
            try sequence.consume(.result(frame))
        }
    }

    @Test func validMarkdownResultAccepted() throws {
        var sequence = Self.fetchSequence()
        let frame = try Self.makeFrame(
            resultType: .markdown, resultMIMEType: nil, identifier: "PARENT01")
        try sequence.consume(.result(frame))
        let terminal = try sequence.finish()
        #expect(terminal == .result(frame))
    }

    @Test func validMarkdownResultWithExplicitMarkdownMIMEAccepted() throws {
        var sequence = Self.fetchSequence()
        let frame = try Self.makeFrame(
            resultType: .markdown,
            resultMIMEType: Self.markdownMIME())
        try sequence.consume(.result(frame))
        #expect(try sequence.finish() == .result(frame))
    }

    @Test func validSourceBytesResultAccepted() throws {
        var sequence = Self.fetchSequence()
        let frame = try Self.makeFrame(
            resultType: .sourceBytes,
            resultMIMEType: Self.pdfMIME(),
            originalFilename: "paper.pdf")
        try sequence.consume(.result(frame))
        #expect(try sequence.finish() == .result(frame))
    }

    /// The sequence's `fetcherResultTypeMismatch` branch is defense in
    /// depth: the validating `ExtractorResultFrame` init (and its decoder)
    /// reject every contradictory tag/MIME combination first, so such a
    /// frame cannot reach a sequence through a public constructor. The
    /// init rejections below pin that gate; this test documents the layering.
    @Test func contradictoryTagMIMECombinationsRejectedAtFrameConstruction() throws {
        // markdown tag + a non-markdown source MIME
        #expect(throws: (any Error).self) {
            _ = try Self.makeFrame(resultType: .markdown, resultMIMEType: Self.pdfMIME())
        }
        // source-bytes tag + no MIME
        #expect(throws: (any Error).self) {
            _ = try Self.makeFrame(resultType: .sourceBytes, resultMIMEType: nil)
        }
        // source-bytes tag + the markdown MIME
        #expect(throws: (any Error).self) {
            _ = try Self.makeFrame(
                resultType: .sourceBytes, resultMIMEType: Self.markdownMIME())
        }
    }

    // MARK: - Sequence: revision gating

    @Test func revisionFourRejectsResultTypeField() throws {
        var sequence = Self.fetchSequence(protocolRevision: .v4, isFetcherRequest: false)
        let frame = try Self.makeFrame(resultType: .markdown, resultMIMEType: nil)
        #expect(throws: ExtractorProtocolSequenceError.fetchResultFieldsRequireProtocolRevision5) {
            try sequence.consume(.result(frame))
        }
    }

    @Test func revisionFourRejectsOriginalFilenameField() throws {
        var sequence = Self.fetchSequence(protocolRevision: .v4, isFetcherRequest: false)
        let frame = try Self.makeFrame(originalFilename: "paper.pdf")
        #expect(throws: ExtractorProtocolSequenceError.fetchResultFieldsRequireProtocolRevision5) {
            try sequence.consume(.result(frame))
        }
    }

    @Test func revisionThreeRejectsRevisionFourResultFields() throws {
        var sequence = Self.fetchSequence(protocolRevision: .v3, isFetcherRequest: false)
        // resultMIMEType is a revision-4 field; articleMetadata.identifier
        // is too. Both fail closed against an older request revision.
        let mimeFrame = try Self.makeFrame(resultMIMEType: Self.pdfMIME())
        #expect(throws: ExtractorProtocolSequenceError.resultFieldsRequireProtocolRevision4) {
            try sequence.consume(.result(mimeFrame))
        }
        var second = Self.fetchSequence(protocolRevision: .v3, isFetcherRequest: false)
        let identifierFrame = try ExtractorResultFrame(
            requestID: Self.requestID,
            outputPath: Self.outputPath,
            markdownByteCount: 3,
            articleMetadata: try ExtractorArticleMetadata(identifier: "PARENT01"))
        #expect(throws: ExtractorProtocolSequenceError.resultFieldsRequireProtocolRevision4) {
            try second.consume(.result(identifierFrame))
        }
    }

    // MARK: - Fetch request filename policy

    @Test func fetchRequestFilenameValidation() throws {
        // Accepts plain display names.
        #expect(throws: Never.self) {
            try ExtractorFetchRequest.validateFilename("paper.pdf")
        }
        #expect(throws: Never.self) {
            try ExtractorFetchRequest.validateFilename("Zotero attachment (1)")
        }
        // Rejects: empty, over-limit, NUL, separators, dot entries.
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename("")
        }
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename(String(repeating: "a", count: 1_025))
        }
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename("paper\u{0}.pdf")
        }
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename("dir/paper.pdf")
        }
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename("dir\\paper.pdf")
        }
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename(".")
        }
        #expect(throws: (any Error).self) {
            try ExtractorFetchRequest.validateFilename("..")
        }
    }

    // MARK: - ProcessPackageFetcher.interpretedOutcome

    @Test func interpretedOutcomeRejectsDeclaredSizeMismatch() throws {
        let frame = try Self.makeFrame(byteCount: 5, resultType: .markdown, resultMIMEType: nil)
        #expect(throws: ProcessPackageRunError.declaredSizeMismatch) {
            _ = try ProcessPackageFetcher.interpretedOutcome(
                frame: frame, outputData: Data("# hi".utf8))
        }
    }

    @Test func interpretedOutcomeRejectsMissingTypeTag() throws {
        let frame = try Self.makeFrame(byteCount: 4, resultType: nil, resultMIMEType: nil)
        #expect(throws: ProcessPackageRunError.fetcherResultTypeMissing) {
            _ = try ProcessPackageFetcher.interpretedOutcome(
                frame: frame, outputData: Data("# hi".utf8))
        }
    }

    @Test func interpretedOutcomeRejectsInvalidUTF8Markdown() throws {
        let data = Data([0xFF, 0xFE, 0xFD])
        let frame = try Self.makeFrame(byteCount: data.count, resultType: .markdown, resultMIMEType: nil)
        #expect(throws: ProcessPackageRunError.invalidOutputEncoding) {
            _ = try ProcessPackageFetcher.interpretedOutcome(frame: frame, outputData: data)
        }
    }

    @Test func interpretedOutcomeRejectsEmptySourceBytes() throws {
        let frame = try Self.makeFrame(
            byteCount: 0, resultType: .sourceBytes, resultMIMEType: Self.pdfMIME())
        #expect(throws: ProcessPackageRunError.emptyFetchResult) {
            _ = try ProcessPackageFetcher.interpretedOutcome(frame: frame, outputData: Data())
        }
    }

    /// A `source-bytes` result without a concrete MIME cannot be constructed
    /// through the validating frame init, so `interpretedOutcome`'s mismatch
    /// guard is unreachable from public API — pinned at the frame layer above.
    @Test func interpretedOutcomeValidMarkdownProducesTypedOutcome() throws {
        let data = Data("# Converted notes\n".utf8)
        let frame = try Self.makeFrame(
            byteCount: data.count,
            resultType: .markdown,
            resultMIMEType: nil,
            identifier: "PARENT02")
        let outcome = try ProcessPackageFetcher.interpretedOutcome(frame: frame, outputData: data)
        guard case .markdown(let markdown) = outcome else {
            Issue.record("expected a markdown fetch outcome")
            return
        }
        #expect(markdown.markdown == String(decoding: data, as: UTF8.self))
        #expect(markdown.reportedMetadata.toolName == "zotero")
        #expect(markdown.articleMetadata?.identifier == "PARENT02")
    }

    @Test func interpretedOutcomeValidSourceBytesProducesTypedOutcome() throws {
        let data = Data("%PDF-1.4 fixture".utf8)
        let frame = try Self.makeFrame(
            byteCount: data.count,
            resultType: .sourceBytes,
            resultMIMEType: Self.pdfMIME(),
            originalFilename: "paper.pdf",
            identifier: "PARENT01")
        let outcome = try ProcessPackageFetcher.interpretedOutcome(frame: frame, outputData: data)
        guard case .sourceBytes(let bytes) = outcome else {
            Issue.record("expected a source-bytes fetch outcome")
            return
        }
        #expect(bytes.bytes == data)
        #expect(bytes.mimeType.rawValue == "application/pdf")
        #expect(bytes.originalFilename == "paper.pdf")
        #expect(bytes.articleMetadata?.identifier == "PARENT01")
    }

    // MARK: - ExtractorRequestEnvelope routing

    private static func fetchRequest() throws -> ExtractorFetchRequest {
        try ExtractorFetchRequest(
            requestID: requestID,
            mimeType: try ExtractorMIMEType(validating: ContentTypeRegistry.zoteroAttachment),
            originalFilename: "ABCD1234",
            remoteURL: ExtractorRemoteSourceURL(validating: "https://api.zotero.org/users/1/items/ABCD1234/file"),
            outputPath: outputPath,
            deadlineMillisecondsSince1970: 4_102_444_800_000)
    }

    private static func extractorRequest(
        protocolRevision: ExtractorProtocolRevision
    ) throws -> ExtractorProtocolRequest {
        try ExtractorProtocolRequest(
            requestID: requestID,
            protocolRevision: protocolRevision,
            kind: .pdf,
            mimeType: try Self.pdfMIME(),
            originalFilename: "paper.pdf",
            inputPath: try ExtractorRelativePath(validating: "input/doc.pdf"),
            outputPath: try ExtractorRelativePath(validating: "output/markdown"),
            deadlineMillisecondsSince1970: 4_102_444_800_000)
    }

    @Test func envelopeDecodesV5FetchPayloadAsFetch() throws {
        let request = try Self.fetchRequest()
        let data = try JSONEncoder().encode(request)
        let envelope = try ExtractorRequestEnvelope.decode(data)
        #expect(envelope.isFetcher)
        guard case .fetch(let decoded) = envelope else {
            Issue.record("expected a fetch envelope")
            return
        }
        #expect(decoded.requestID == request.requestID)
        #expect(decoded.remoteURL == request.remoteURL)
        #expect(decoded.originalFilename == "ABCD1234")
        #expect(decoded.protocolRevision == .v5)
    }

    @Test func envelopeDecodesV5ExtractorRoleAsExtractor() throws {
        let request = try Self.extractorRequest(protocolRevision: .v5)
        let data = try JSONEncoder().encode(request)
        let envelope = try ExtractorRequestEnvelope.decode(data)
        #expect(envelope.isFetcher == false)
        guard case .extractor(let decoded) = envelope else {
            Issue.record("expected an extractor envelope")
            return
        }
        #expect(decoded.protocolRevision == .v5)
        #expect(decoded.kind == .pdf)
    }

    @Test func envelopeDecodesV4PayloadAsExtractorAndRejectsRoleKey() throws {
        let request = try Self.extractorRequest(protocolRevision: .v4)
        let data = try JSONEncoder().encode(request)

        // Without a role key: revision ≤ 4 decodes the extractor shape.
        let envelope = try ExtractorRequestEnvelope.decode(data)
        guard case .extractor(let decoded) = envelope else {
            Issue.record("expected an extractor envelope for a v4 payload")
            return
        }
        #expect(decoded.protocolRevision == .v4)

        // With a role key: revision ≤ 4 fails closed (unknown field).
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["role"] = "extractor"
        let tainted = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try ExtractorRequestEnvelope.decode(tainted)
        }
    }

    @Test func v5FetchDecodeRejectsExtractorKeys() throws {
        let data = try JSONEncoder().encode(Self.fetchRequest())
        for key in ["kind", "inputTransport", "inputPath"] {
            var object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[key] = key == "kind" ? "pdf" : "operation-file"
            let tainted = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self, "fetch decode must reject the \(key) key") {
                _ = try ExtractorRequestEnvelope.decode(tainted)
            }
        }
    }

    /// A revision-5 EXTRACTOR request keeps the revision-3 wire shape —
    /// `remote-url` included (skeptic-review F3): the JSON round-trip must
    /// decode, and the envelope must route it to the extractor arm.
    @Test func v5ExtractorRequestKeepsRemoteURLTransport() throws {
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v5,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "doc.pdf",
            remoteURL: ExtractorRemoteSourceURL(
                validating: "https://example.com/doc.pdf"),
            outputPath: ExtractorRelativePath(validating: "output/result.md"),
            deadlineMillisecondsSince1970: 9_999_999_999_999)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            ExtractorProtocolRequest.self, from: data)
        #expect(decoded == request)
        // The envelope routes it as an extractor request, not a fetch.
        guard case .extractor(let envelope) = try ExtractorRequestEnvelope.decode(data) else {
            Issue.record("expected the extractor arm")
            return
        }
        #expect(envelope == request)
        #expect(envelope.operationInput.transport == .remoteURL)
    }

    /// The execution boundary's redaction pass must carry the revision-5
    /// fetch fields through: the result tag has no text surface, and the
    /// display filename is package-controlled text that MUST be redacted.
    /// A future edit dropping `resultType` here would fail every fetch with
    /// fetcherResultTypeMissing; this test pins it.
    @Test func redactedResultFrameCarriesFetchFieldsAndRedactsFilename() throws {
        let redactor = ExtractorSecretRedactor(values: ["secret-value"])
        let frame = try ExtractorResultFrame(
            requestID: ExtractorRequestID(),
            outputPath: ExtractorRelativePath(validating: "output/result.md"),
            markdownByteCount: 3,
            metadata: ExtractorReportedMetadata(toolName: "zotero"),
            articleMetadata: ExtractorArticleMetadata(
                title: "A Study of secret-value",
                identifier: "PARENT01"),
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"),
            resultType: .sourceBytes,
            originalFilename: "secret-value.pdf")
        let redacted = try PreparedProcessOperation.redactedResultFrame(
            frame, redactor: redactor)
        #expect(redacted.resultType == .sourceBytes)
        #expect(redacted.resultMIMEType?.rawValue == "application/pdf")
        #expect(redacted.originalFilename == "[redacted].pdf")
        #expect(redacted.articleMetadata?.title == "A Study of [redacted]")
        #expect(redacted.articleMetadata?.identifier == "PARENT01")
    }
}
