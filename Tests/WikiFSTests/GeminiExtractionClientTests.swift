import Foundation
import Testing
@testable import WikiFSCore

/// `GeminiExtractionClient` request-building, decoding, status mapping, and
/// end-to-end `convert` — driven entirely by the `FakeHTTPFetcher`, no real
/// network. Mirrors `AnthropicExtractionClientTests`.
struct GeminiExtractionClientTests {

    private let apiKey = "AIza-test"
    private let pdf = Data("%PDF-1.4 fake".utf8)

    private func client(_ fetcher: FakeHTTPFetcher) -> GeminiExtractionClient {
        GeminiExtractionClient(model: "gemini-3.5-flash", apiKey: apiKey, fetcher: fetcher)
    }

    private func json(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    private func successData(_ md: String, finish: String = "STOP") throws -> Data {
        try json([
            "candidates": [["content": ["parts": [["text": md]]], "finishReason": finish]],
        ])
    }

    // MARK: - buildRequest

    @Test func buildRequestTargetsGenerateContentAndCarriesKey() throws {
        let request = try GeminiExtractionClient.buildRequest(
            pdfData: pdf, model: "gemini-3.5-flash", apiKey: apiKey,
            baseURL: URL(string: "https://generativelanguage.googleapis.com")!)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == apiKey)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func buildRequestBodyEmbedsInlineDataAndPrompt() throws {
        let request = try GeminiExtractionClient.buildRequest(
            pdfData: pdf, model: "gemini-3.5-flash", apiKey: "k",
            baseURL: URL(string: "https://generativelanguage.googleapis.com")!)

        let body = try #require(request.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let contents = try #require(obj["contents"] as? [[String: Any]])
        let first = try #require(contents.first)
        #expect(first["role"] as? String == "user")
        let parts = try #require(first["parts"] as? [[String: Any]])
        #expect(parts.count == 2)

        let inline = try #require(parts[0]["inline_data"] as? [String: Any])
        #expect(inline["mime_type"] as? String == "application/pdf")
        #expect(inline["data"] as? String == pdf.base64EncodedString())

        #expect(parts[1]["text"] as? String == ExtractionPrompts.instruction)

        let sys = try #require(obj["systemInstruction"] as? [String: Any])
        let sysParts = try #require(sys["parts"] as? [[String: Any]])
        #expect(sysParts.first?["text"] as? String == ExtractionPrompts.system)

        let gen = try #require(obj["generationConfig"] as? [String: Any])
        #expect(gen["maxOutputTokens"] as? Int == GeminiExtractionClient.maxOutputTokens)
        #expect(gen["temperature"] as? Double == 0)
    }

    // MARK: - decode

    @Test func decodeConcatenatesTextParts() throws {
        let data = try json([
            "candidates": [["content": ["parts": [["text": "# Title"], ["text": "\n\nbody"]]],
                           "finishReason": "STOP"]]])
        let decoded = try GeminiExtractionClient.decode(data: data)
        #expect(decoded.markdown == "# Title\n\nbody")
        #expect(decoded.finishReason == "STOP")
    }

    @Test func decodeIgnoresNonTextParts() throws {
        let data = try json([
            "candidates": [["content": ["parts": [["executableCode": ["code": "x"]], ["text": "only this"]]]]]])
        #expect(try GeminiExtractionClient.decode(data: data).markdown == "only this")
    }

    @Test func decodeBlockedOnPromptFeedback() throws {
        let data = try json(["promptFeedback": ["blockReason": "SAFETY"]])
        #expect(throws: GeminiExtractionClient.Error.self) {
            try GeminiExtractionClient.decode(data: data)
        }
    }

    @Test func decodeBlockedOnSafetyFinishReason() throws {
        let data = try json([
            "candidates": [["content": ["parts": []], "finishReason": "SAFETY"]]])
        #expect(throws: GeminiExtractionClient.Error.self) {
            try GeminiExtractionClient.decode(data: data)
        }
    }

    @Test func decodeEmptyOutputThrows() throws {
        let data = try json(["candidates": [["content": ["parts": [["text": "  "]]], "finishReason": "STOP"]]])
        #expect(throws: GeminiExtractionClient.Error.emptyOutput) {
            try GeminiExtractionClient.decode(data: data)
        }
    }

    @Test func decodeMalformedThrows() {
        #expect(throws: GeminiExtractionClient.Error.self) {
            try GeminiExtractionClient.decode(data: Data("not json".utf8))
        }
    }

    @Test func decodeKeepsMaxTokensFinishReason() throws {
        // MAX_TOKENS is not blocking — the (partial) text is returned and the
        // caller warns. finishReason is surfaced for that check.
        let data = try json([
            "candidates": [["content": ["parts": [["text": "partial"]]], "finishReason": "MAX_TOKENS"]]])
        let decoded = try GeminiExtractionClient.decode(data: data)
        #expect(decoded.markdown == "partial")
        #expect(decoded.finishReason == "MAX_TOKENS")
    }

    // MARK: - checkStatus

    @Test func checkStatusMapping() {
        #expect(throws: Never.self) { try GeminiExtractionClient.checkStatus(200, data: Data()) }
        #expect(throws: GeminiExtractionClient.Error.unauthorized) {
            try GeminiExtractionClient.checkStatus(401, data: Data())
        }
        #expect(throws: GeminiExtractionClient.Error.unauthorized) {
            try GeminiExtractionClient.checkStatus(403, data: Data())
        }
        #expect(throws: GeminiExtractionClient.Error.httpStatus(500, "{bad}".prefix(300).description)) {
            try GeminiExtractionClient.checkStatus(500, data: Data("{bad}".utf8))
        }
    }

    // MARK: - convert (end-to-end with the fake fetcher)

    @Test func convertReturnsMarkdownOnSuccess() async throws {
        let fetcher = FakeHTTPFetcher(body: try successData("# Hello\n\nworld"))
        let md = try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        #expect(md == "# Hello\n\nworld")
    }

    @Test func convertThrowsMissingAPIKeyWhenBlank() async throws {
        let fetcher = FakeHTTPFetcher(body: try successData("x"))  // never reached
        let blank = GeminiExtractionClient(model: "m", apiKey: "   ", fetcher: fetcher)
        await #expect(throws: GeminiExtractionClient.Error.missingAPIKey) {
            try await blank.convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertThrowsTooLargeForOversizedPDF() async throws {
        let oversized = Data(count: GeminiExtractionClient.maxPDFBytes + 1)
        let fetcher = FakeHTTPFetcher(body: try successData("x"))  // never reached
        await #expect(throws: GeminiExtractionClient.Error.tooLarge(byteCount: oversized.count)) {
            try await client(fetcher).convert(pdfData: oversized, filename: "big.pdf", onProgress: nil)
        }
    }

    @Test func convertThrowsUnauthorizedOn401() async throws {
        let fetcher = FakeHTTPFetcher(body: Data(#"{"error":{"message":"bad key"}}"#.utf8), statusCode: 401)
        await #expect(throws: GeminiExtractionClient.Error.unauthorized) {
            try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertWrapsTransportError() async throws {
        let fetcher = FakeHTTPFetcher(responses: [])  // queueExhausted → wrapped as Gemini error
        await #expect(throws: GeminiExtractionClient.Error.self) {
            try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertWarnsOnMaxTokensTruncation() async throws {
        final class Capture: @unchecked Sendable {
            private(set) var lines: [String] = []
            func append(_ s: String) { lines.append(s) }
        }
        let cap = Capture()
        let fetcher = FakeHTTPFetcher(body: try successData("partial", finish: "MAX_TOKENS"))
        _ = try await client(fetcher).convert(
            pdfData: pdf, filename: "p.pdf", onProgress: { cap.append($0) })
        #expect(cap.lines.contains { $0.contains("truncated") })
    }

    // MARK: - verifyConnection

    @Test func verifyConnectionSucceedsOn200() async throws {
        let fetcher = FakeHTTPFetcher(body: Data("{}".utf8))
        try await client(fetcher).verifyConnection()
    }

    @Test func verifyConnectionThrowsUnauthorizedOn401() async throws {
        let fetcher = FakeHTTPFetcher(body: Data("{}".utf8), statusCode: 401)
        await #expect(throws: GeminiExtractionClient.Error.unauthorized) {
            try await client(fetcher).verifyConnection()
        }
    }

    @Test func verifyConnectionThrowsMissingAPIKeyWhenBlank() async throws {
        let blank = GeminiExtractionClient(model: "m", apiKey: "  ", fetcher: FakeHTTPFetcher(body: "x"))
        await #expect(throws: GeminiExtractionClient.Error.missingAPIKey) {
            try await blank.verifyConnection()
        }
    }

    // MARK: - readiness / displayName

    @Test func readinessNeedsSetupWithoutKey() async {
        let unconfigured = GeminiExtractionClient(model: "m", apiKey: "", fetcher: FakeHTTPFetcher(body: "x"))
        let r = await unconfigured.readiness()
        #expect(r == .needsSetup("Add your Google AI Studio API key in Settings → Extraction."))
    }

    @Test func readinessReadyWithKey() async {
        let r = await client(FakeHTTPFetcher(body: "x")).readiness()
        #expect(r == .ready)
    }

    @Test func displayNameIncludesModel() {
        #expect(client(FakeHTTPFetcher(body: "x")).displayName == "Gemini (gemini-3.5-flash)")
    }
}
