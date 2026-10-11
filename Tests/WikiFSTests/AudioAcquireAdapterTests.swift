import Foundation
import Testing
import WikiFSTypes
import WikiFSCore
@testable import WikiFSEngine

/// The speech arm's host-side acquisition boundary (`AudioAcquireAdapter`).
///
/// The acquisition runs through the GENERIC revision-5 fetcher machinery —
/// there is no second package resolver and no audio-specific kind. These
/// tests pin the boundary the speech floor relies on: binary bytes pass
/// through untouched, a non-`audio/mp4` (or untyped) result fails closed,
/// and the prepared operation's declared-size contract holds at the binary
/// result edge.
@Suite("Audio acquire adapter")
struct AudioAcquireAdapterTests {

    private static let audioMIME = try! ExtractorMIMEType(validating: "audio/mp4")
    private static let wrongMIME = try! ExtractorMIMEType(validating: "application/pdf")

    private static func sourceBytesOutcome(
        bytes: Data,
        mimeType: ExtractorMIMEType?
    ) throws -> ProcessPackageFetchOutcome {
        .sourceBytes(ProcessPackageFetchSourceBytes(
            bytes: bytes,
            mimeType: mimeType ?? Self.audioMIME,
            originalFilename: nil,
            reportedMetadata: try ExtractorReportedMetadata(toolName: "audio-acquire"),
            articleMetadata: nil))
    }

    // MARK: - Binary passthrough

    /// Media bytes are preserved byte-for-byte. A non-UTF-8 sequence must
    /// survive exactly — the boundary never decodes, normalizes, or
    /// lossy-replaces binary content.
    @Test func preservesNonUTF8Bytes() throws {
        let binary = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                           0x4D, 0x34, 0x41, 0x20, 0xFF, 0xFE, 0x80, 0xC3])
        let outcome = try Self.sourceBytesOutcome(bytes: binary, mimeType: Self.audioMIME)
        let validated = try AudioAcquireAdapter.validatedAudioBytes(from: outcome)
        #expect(validated.bytes == binary)
        #expect(validated.mimeType == Self.audioMIME)
    }

    // MARK: - MIME contract

    /// A `source-bytes` result with no concrete `audio/mp4` MIME fails
    /// closed — and a `markdown` result can never be audio at all.
    @Test func rejectsMissingOrWrongMIME() throws {
        // Wrong MIME.
        let wrong = try Self.sourceBytesOutcome(
            bytes: Data([0x01, 0x02]), mimeType: Self.wrongMIME)
        #expect(throws: AudioAcquireError.wrongResultMIMEType) {
            try AudioAcquireAdapter.validatedAudioBytes(from: wrong)
        }
        // The markdown arm is structurally a different case.
        let markdown = ProcessPackageFetchOutcome.markdown(ProcessPackageFetchMarkdown(
            markdown: "not audio",
            reportedMetadata: .empty,
            articleMetadata: nil))
        #expect(throws: AudioAcquireError.notSourceBytesResult) {
            try AudioAcquireAdapter.validatedAudioBytes(from: markdown)
        }
    }

    // MARK: - Prepared-operation binary result boundary

    /// The declared-size contract is enforced by the prepared operation's
    /// result interpreter — the boundary a binary result actually crosses.
    /// A frame declaring more bytes than the output file holds fails before
    /// any consumer sees the bytes.
    @Test func rejectsDeclaredSizeMismatch() throws {
        let frame = try ExtractorResultFrame(
            requestID: ExtractorRequestID(),
            outputPath: try ExtractorRelativePath(validating: "output/fetch/result"),
            markdownByteCount: 64,
            warnings: [],
            metadata: .empty,
            articleMetadata: nil,
            resultMIMEType: Self.audioMIME,
            resultType: .sourceBytes,
            originalFilename: nil)
        #expect(throws: ProcessPackageRunError.declaredSizeMismatch) {
            try ProcessPackageFetcher.interpretedOutcome(
                frame: frame, outputData: Data([0x01, 0x02, 0x03]))
        }
        // The same boundary accepts matching binary bytes (a non-audio MIME
        // like `application/pdf` is a legitimate FETCH result — the speech
        // edge above is what rejects it).
        let ok = try ProcessPackageFetcher.interpretedOutcome(
            frame: frame, outputData: Data(repeating: 0x2A, count: 64))
        guard case .sourceBytes(let bytes) = ok else {
            Issue.record("expected a source-bytes outcome")
            return
        }
        #expect(bytes.bytes.count == 64)
    }
}
