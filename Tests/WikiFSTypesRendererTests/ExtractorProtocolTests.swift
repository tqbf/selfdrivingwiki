import Foundation
import Testing
import WikiFSTypes

struct ExtractorProtocolTests {
    @Test func validProgressAndResultRoundTrip() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        let frames: [ExtractorProtocolFrame] = [
            .progress(try ExtractorProgressFrame(requestID: requestID, completedUnitCount: 1, totalUnitCount: 2, message: "reading")),
            .diagnostic(try ExtractorDiagnosticFrame(requestID: requestID, message: "fixture diagnostic")),
            .result(try ExtractorResultFrame(
                requestID: requestID,
                outputPath: expectedOutputPath,
                markdownByteCount: 42,
                warnings: ["one warning"],
                metadata: ExtractorReportedMetadata(toolName: "fixture", toolVersion: "1.0.0")))
        ]
        var sequence = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 2)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for frame in frames {
            let roundTrip = try decoder.decode(ExtractorProtocolFrame.self, from: encoder.encode(frame))
            #expect(roundTrip == frame)
            try sequence.consume(roundTrip)
        }
        #expect(try sequence.finish() == frames.last)
    }

    @Test func articleMetadataRoundTripsAndIsOmittedWhenAbsent() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        let metadata = try ExtractorArticleMetadata(
            title: "Example",
            author: "Jane Doe",
            description: "An example article",
            published: "2026-08-26",
            wordCount: 321)
        let populated = try ExtractorResultFrame(
            requestID: requestID,
            outputPath: expectedOutputPath,
            markdownByteCount: 10,
            articleMetadata: metadata)
        let roundTrip = try JSONDecoder().decode(
            ExtractorResultFrame.self,
            from: JSONEncoder().encode(populated))
        #expect(roundTrip.articleMetadata == metadata)

        let bare = try ExtractorResultFrame(
            requestID: requestID,
            outputPath: expectedOutputPath,
            markdownByteCount: 1)
        let bareJSON = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        #expect(bareJSON.contains("articleMetadata") == false)
        let bareRoundTrip = try JSONDecoder().decode(
            ExtractorResultFrame.self,
            from: JSONEncoder().encode(bare))
        #expect(bareRoundTrip.articleMetadata == nil)
    }

    @Test func rejectsInvalidArticleMetadata() throws {
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(title: "")
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(title: String(repeating: "x", count: 2_048))
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(wordCount: -1)
        }
        #expect(throws: Error.self) {
            _ = try ExtractorArticleMetadata(wordCount: 10_000_001)
        }
    }

    @Test func rejectsMismatchedAndExcessProgress() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        var mismatch = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        #expect(throws: ExtractorProtocolSequenceError.requestMismatch) {
            try mismatch.consume(.progress(ExtractorProgressFrame(requestID: ExtractorRequestID())))
        }

        var excess = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        let progress = try ExtractorProtocolFrame.progress(ExtractorProgressFrame(requestID: requestID))
        try excess.consume(progress)
        #expect(throws: ExtractorProtocolSequenceError.tooManyProgressEvents) {
            try excess.consume(progress)
        }
    }

    @Test func rejectsDuplicateTerminalOutputAfterTerminalAndWrongOutputPath() throws {
        let requestID = ExtractorRequestID()
        let expectedOutputPath = try outputPath()
        let result = try ExtractorProtocolFrame.result(ExtractorResultFrame(
            requestID: requestID,
            outputPath: expectedOutputPath,
            markdownByteCount: 0))
        var duplicate = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        try duplicate.consume(result)
        #expect(throws: ExtractorProtocolSequenceError.duplicateTerminal) { try duplicate.consume(result) }

        var output = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        try output.consume(result)
        #expect(throws: ExtractorProtocolSequenceError.outputAfterTerminal) {
            try output.consume(.diagnostic(ExtractorDiagnosticFrame(requestID: requestID, message: "late")))
        }

        var wrongPath = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: expectedOutputPath,
            maximumProgressEventCount: 1)
        let mismatchedResult = try ExtractorProtocolFrame.result(ExtractorResultFrame(
            requestID: requestID,
            outputPath: ExtractorRelativePath(validating: "output/other.md"),
            markdownByteCount: 0))
        #expect(throws: ExtractorProtocolSequenceError.outputPathMismatch) {
            try wrongPath.consume(mismatchedResult)
        }
    }

    @Test func missingTerminalAndInvalidRequestPathsAreRejected() throws {
        let requestID = ExtractorRequestID()
        let sequence = ExtractorProtocolSequence(
            requestID: requestID,
            expectedOutputPath: try outputPath(),
            maximumProgressEventCount: 1)
        #expect(throws: ExtractorProtocolSequenceError.missingTerminal) { _ = try sequence.finish() }
        #expect(throws: ExtractorValidationError.invalidManifest("input and output paths match")) {
            _ = try ExtractorProtocolRequest(
                requestID: requestID,
                protocolRevision: .v1,
                kind: .pdf,
                mimeType: ExtractorMIMEType(validating: "application/pdf"),
                originalFilename: "source.pdf",
                inputPath: ExtractorRelativePath(validating: "source.pdf"),
                outputPath: ExtractorRelativePath(validating: "source.pdf"),
                deadlineMillisecondsSince1970: 1)
        }
    }

    private func outputPath() throws -> ExtractorRelativePath {
        try ExtractorRelativePath(validating: "output/result.md")
    }
}
