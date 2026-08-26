import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

struct ExtractorJSONLinesDecoderTests {
    @Test func decodesSplitFramesAndTerminal() throws {
        let requestID = ExtractorRequestID()
        let progress = try encoded(.progress(ExtractorProgressFrame(requestID: requestID, message: "start")))
        let result = try encoded(.result(ExtractorResultFrame(
            requestID: requestID,
            outputPath: ExtractorRelativePath(validating: "output/result.md"),
            markdownByteCount: 10)))
        var bytes = progress
        bytes.append(result)
        let split = bytes.count / 2
        var decoder = ExtractorJSONLinesDecoder()
        let first = try decoder.append(bytes.prefix(split))
        let second = try decoder.append(bytes.suffix(from: split))
        #expect(first.count + second.count == 2)
        try decoder.finish()
    }

    @Test func rejectsMalformedUTF8JSONAndOversizedFrame() throws {
        var utf8 = ExtractorJSONLinesDecoder(maximumFrameByteCount: 32)
        #expect(throws: ExtractorJSONLinesError.malformedUTF8) {
            _ = try utf8.append(Data([0xff, 0x0a]))
        }
        var json = ExtractorJSONLinesDecoder(maximumFrameByteCount: 32)
        #expect(throws: ExtractorJSONLinesError.malformedJSON) {
            _ = try json.append(Data("not-json\n".utf8))
        }
        var oversized = ExtractorJSONLinesDecoder(maximumFrameByteCount: 4)
        #expect(throws: ExtractorJSONLinesError.frameTooLarge) {
            _ = try oversized.append(Data("12345".utf8))
        }
    }

    @Test func rejectsIncompleteFrameAndOutputAfterTerminal() throws {
        var incomplete = ExtractorJSONLinesDecoder()
        _ = try incomplete.append(Data("{}".utf8))
        #expect(throws: ExtractorJSONLinesError.incompleteFinalFrame) { try incomplete.finish() }

        let requestID = ExtractorRequestID()
        var terminal = ExtractorJSONLinesDecoder()
        _ = try terminal.append(encoded(.failure(ExtractorFailureFrame(
            requestID: requestID,
            cause: .extractionFailure,
            message: "failed"))))
        #expect(throws: ExtractorJSONLinesError.outputAfterTerminal) {
            _ = try terminal.append(Data("{}\n".utf8))
        }
    }

    private func encoded(_ frame: ExtractorProtocolFrame) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }
}
