import Foundation
import Testing
@testable import WikiFSCore

/// `AnthropicExtractionClient` request-building, decoding, status mapping, and
/// end-to-end `convert` — driven entirely by the `FakeHTTPFetcher` returning
/// canned `(Data, Int)` pairs, no real network. Mirrors `ZoteroClientTests`.
struct AnthropicExtractionClientTests {

    private let apiKey = "sk-ant-test"
    private let pdf = Data("%PDF-1.4 fake".utf8)

    private func client(_ fetcher: FakeHTTPFetcher) -> AnthropicExtractionClient {
        AnthropicExtractionClient(model: "claude-opus-4-8", apiKey: apiKey, fetcher: fetcher)
    }

    /// Build a response body from a dict so quoting/escaping can't go wrong.
    private func json(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    private func successData(_ md: String, stop: String? = "end_turn") throws -> Data {
        var obj: [String: Any] = ["content": [["type": "text", "text": md]]]
        if let stop { obj["stop_reason"] = stop }
        return try json(obj)
    }

    // MARK: - buildRequest

    @Test func buildRequestCarriesAuthHeadersAndURL() throws {
        let request = try AnthropicExtractionClient.buildRequest(
            pdfData: pdf, model: "claude-opus-4-8", apiKey: apiKey,
            baseURL: URL(string: "https://api.anthropic.com")!)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == apiKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func buildRequestBodyEmbedsBase64DocumentBlockAndInstruction() throws {
        let request = try AnthropicExtractionClient.buildRequest(
            pdfData: pdf, model: "claude-opus-4-8", apiKey: "k",
            baseURL: URL(string: "https://api.anthropic.com")!)

        let body = try #require(request.httpBody)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(obj["model"] as? String == "claude-opus-4-8")
        #expect(obj["max_tokens"] as? Int == AnthropicExtractionClient.maxTokens)
        #expect(obj["system"] as? String == AnthropicExtractionClient.extractionSystemPrompt)

        let message = try #require((obj["messages"] as? [[String: Any]])?.first)
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2)

        let doc = content[0]
        #expect(doc["type"] as? String == "document")
        let source = try #require(doc["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "application/pdf")
        #expect(source["data"] as? String == pdf.base64EncodedString())

        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == AnthropicExtractionClient.extractionUserInstruction)
    }

    // MARK: - decode

    @Test func decodeConcatenatesTextBlocks() throws {
        let data = try json([
            "stop_reason": "end_turn",
            "content": [
                ["type": "text", "text": "# Title\n\n"],
                ["type": "text", "text": "body line"],
            ]])
        let decoded = try AnthropicExtractionClient.decode(data: data)
        #expect(decoded.markdown == "# Title\n\nbody line")
        #expect(decoded.stopReason == "end_turn")
    }

    @Test func decodeIgnoresNonTextBlocks() throws {
        let data = try json([
            "content": [["type": "tool_use", "id": "x"], ["type": "text", "text": "only this"]]])
        #expect(try AnthropicExtractionClient.decode(data: data).markdown == "only this")
    }

    @Test func decodeRefusalThrows() throws {
        let data = try json(["stop_reason": "refusal", "content": []])
        #expect(throws: AnthropicExtractionClient.Error.refused) {
            try AnthropicExtractionClient.decode(data: data)
        }
    }

    @Test func decodeEmptyOutputThrows() throws {
        let data = try json(["stop_reason": "end_turn", "content": []])
        #expect(throws: AnthropicExtractionClient.Error.emptyOutput) {
            try AnthropicExtractionClient.decode(data: data)
        }
    }

    @Test func decodeWhitespaceOnlyOutputThrows() throws {
        let data = try json(["content": [["type": "text", "text": "  \n  "]]])
        #expect(throws: AnthropicExtractionClient.Error.emptyOutput) {
            try AnthropicExtractionClient.decode(data: data)
        }
    }

    @Test func decodeMalformedThrows() {
        #expect(throws: AnthropicExtractionClient.Error.self) {
            try AnthropicExtractionClient.decode(data: Data("not json".utf8))
        }
    }

    // MARK: - checkStatus

    @Test func checkStatusMapping() throws {
        #expect(throws: Never.self) { try AnthropicExtractionClient.checkStatus(200, data: Data()) }
        #expect(throws: Never.self) { try AnthropicExtractionClient.checkStatus(299, data: Data()) }
        #expect(throws: AnthropicExtractionClient.Error.unauthorized) {
            try AnthropicExtractionClient.checkStatus(401, data: Data())
        }
        #expect(throws: AnthropicExtractionClient.Error.httpStatus(500, "{bad}".prefix(300).description)) {
            try AnthropicExtractionClient.checkStatus(500, data: Data("{bad}".utf8))
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
        let blankKey = AnthropicExtractionClient(model: "m", apiKey: "   ", fetcher: fetcher)
        await #expect(throws: AnthropicExtractionClient.Error.missingAPIKey) {
            try await blankKey.convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertThrowsTooLargeForOversizedPDF() async throws {
        let oversized = Data(count: AnthropicExtractionClient.maxPDFBytes + 1)
        let fetcher = FakeHTTPFetcher(body: try successData("x"))  // never reached
        await #expect(throws: AnthropicExtractionClient.Error.tooLarge(byteCount: oversized.count)) {
            try await client(fetcher).convert(pdfData: oversized, filename: "big.pdf", onProgress: nil)
        }
    }

    @Test func convertThrowsUnauthorizedOn401() async throws {
        let fetcher = FakeHTTPFetcher(body: Data(#"{"error":"bad key"}"#.utf8), statusCode: 401)
        await #expect(throws: AnthropicExtractionClient.Error.unauthorized) {
            try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertWrapsTransportErrorAsNetwork() async throws {
        // An empty fake queue throws `queueExhausted`, which convert must wrap
        // as a Docling/Anthropic error (it's not an `AnthropicExtractionClient.Error`).
        let fetcher = FakeHTTPFetcher(responses: [])
        await #expect(throws: AnthropicExtractionClient.Error.self) {
            try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertWarnsOnMaxTokensTruncation() async throws {
        final class Capture: @unchecked Sendable {
            private(set) var lines: [String] = []
            func append(_ s: String) { lines.append(s) }
        }
        let cap = Capture()
        let fetcher = FakeHTTPFetcher(body: try successData("partial", stop: "max_tokens"))
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
        await #expect(throws: AnthropicExtractionClient.Error.unauthorized) {
            try await client(fetcher).verifyConnection()
        }
    }

    @Test func verifyConnectionThrowsMissingAPIKeyWhenBlank() async throws {
        let blank = AnthropicExtractionClient(model: "m", apiKey: "  ", fetcher: FakeHTTPFetcher(body: "x"))
        await #expect(throws: AnthropicExtractionClient.Error.missingAPIKey) {
            try await blank.verifyConnection()
        }
    }

    // MARK: - readiness

    @Test func readinessNeedsSetupWithoutKey() async {
        let unconfigured = AnthropicExtractionClient(model: "m", apiKey: "", fetcher: FakeHTTPFetcher(body: "x"))
        let r = await unconfigured.readiness()
        #expect(r == .needsSetup("Add your Anthropic API key in Settings → Extraction."))
    }

    @Test func readinessReadyWithKey() async {
        let r = await client(FakeHTTPFetcher(body: "x")).readiness()
        #expect(r == .ready)
    }
}
