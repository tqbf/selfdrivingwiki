import Foundation
import Testing
@testable import WikiFSCore

/// `DoclingServeClient` multipart-building, decoding, status mapping, and
/// end-to-end `convert` — driven entirely by the `FakeHTTPFetcher`, no real
/// network. Mirrors `ZoteroClientTests` / `AnthropicExtractionClientTests`.
struct DoclingServeClientTests {

    private let pdf = Data("%PDF-1.4 fake".utf8)

    private func client(_ fetcher: FakeHTTPFetcher) -> DoclingServeClient {
        DoclingServeClient(endpoint: "http://localhost:5001", fetcher: fetcher)
    }

    /// Build a response body from a dict so quoting/escaping can't go wrong
    /// (markdown headings contain `"#`, which would break a `#"..."#` literal).
    private func json(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - buildRequest

    @Test func buildRequestURLAppendsConvertFilePath() throws {
        let request = try DoclingServeClient.buildRequest(
            endpoint: "http://localhost:5001", apiToken: nil, filename: "p.pdf", pdfData: pdf)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:5001/v1/convert/file")
    }

    @Test func buildRequestStripsTrailingSlash() throws {
        let request = try DoclingServeClient.buildRequest(
            endpoint: "http://host:5001/", apiToken: nil, filename: "p.pdf", pdfData: pdf)
        #expect(request.url?.absoluteString == "http://host:5001/v1/convert/file")
    }

    @Test func buildRequestCarriesMultipartContentTypeWithBoundary() throws {
        let request = try DoclingServeClient.buildRequest(
            endpoint: "http://localhost:5001", apiToken: nil, filename: "p.pdf", pdfData: pdf)
        let ct = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(ct.dropFirst("multipart/form-data; boundary=".count))
        let body = try #require(request.httpBody)
        // The body must be delimited by that boundary, and carry the PDF bytes.
        #expect(String(data: body, encoding: .utf8)?.contains("--\(boundary)") == true)
        #expect(body.range(of: pdf) != nil)
    }

    @Test func buildRequestAttachesTokenHeaderWhenProvided() throws {
        let request = try DoclingServeClient.buildRequest(
            endpoint: "http://localhost:5001", apiToken: "sekret", filename: "p.pdf", pdfData: pdf)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "sekret")
    }

    @Test func buildRequestOmitsTokenHeaderWhenNil() throws {
        let request = try DoclingServeClient.buildRequest(
            endpoint: "http://localhost:5001", apiToken: nil, filename: "p.pdf", pdfData: pdf)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == nil)
    }

    // MARK: - buildMultipartBody (fixed boundary → structure assertions)

    @Test func multipartBodyHasAllParts() throws {
        let boundary = "----TESTBOUNDARY"
        let body = DoclingServeClient.buildMultipartBody(
            boundary: boundary, filename: "report.pdf", pdfData: pdf)
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(text.contains("name=\"to_formats\""))
        #expect(text.contains("md\r\n--\(boundary)"))
        #expect(text.contains("name=\"from_formats\""))
        #expect(text.contains("pdf\r\n--\(boundary)"))

        // The file part carries the filename + content type, and the raw PDF
        // bytes (here printable) appear inside it, then a closing boundary.
        #expect(text.contains("name=\"files\"; filename=\"report.pdf\""))
        #expect(text.contains("Content-Type: application/pdf"))
        #expect(text.contains("%PDF-1.4 fake"))
        #expect(text.hasSuffix("--\(boundary)--\r\n"))
    }

    // MARK: - decode

    @Test func decodePullsMdContent() throws {
        let data = try json(["document": ["md_content": "# Title\n\nbody"], "errors": []])
        #expect(try DoclingServeClient.decode(data: data) == "# Title\n\nbody")
    }

    @Test func decodeEmptyMdThrowsEmptyOutput() throws {
        let data = try json(["document": ["md_content": "   "], "errors": []])
        #expect(throws: DoclingServeClient.Error.emptyOutput) {
            try DoclingServeClient.decode(data: data)
        }
    }

    @Test func decodeMissingDocumentThrowsEmptyOutput() throws {
        let data = try json(["errors": []])
        #expect(throws: DoclingServeClient.Error.emptyOutput) {
            try DoclingServeClient.decode(data: data)
        }
    }

    @Test func decodeSurfacesServerErrorsWhenNoMarkdown() throws {
        let data = try json([
            "document": ["md_content": ""],
            "errors": [
                ["component": "ocr", "error_message": "tesseract missing"],
                ["component": "layout", "error_message": "oom"],
            ]])
        #expect(throws: DoclingServeClient.Error.serverErrors(
            ["tesseract missing", "oom"])) {
            try DoclingServeClient.decode(data: data)
        }
    }

    @Test func decodePrefersMarkdownOverErrors() throws {
        // abort_on_error=false: a non-empty md_content wins even with errors.
        let data = try json([
            "document": ["md_content": "# Recovered"],
            "errors": [["component": "x", "error_message": "minor"]]])
        #expect(try DoclingServeClient.decode(data: data) == "# Recovered")
    }

    @Test func decodeMalformedThrows() {
        #expect(throws: DoclingServeClient.Error.self) {
            try DoclingServeClient.decode(data: Data("not json".utf8))
        }
    }

    // MARK: - checkStatus

    @Test func checkStatusMapping() {
        #expect(throws: Never.self) { try DoclingServeClient.checkStatus(200, data: Data()) }
        #expect(throws: DoclingServeClient.Error.unauthorized) {
            try DoclingServeClient.checkStatus(401, data: Data())
        }
        #expect(throws: DoclingServeClient.Error.unauthorized) {
            try DoclingServeClient.checkStatus(403, data: Data())
        }
        #expect(throws: DoclingServeClient.Error.httpStatus(500, "{bad}".prefix(300).description)) {
            try DoclingServeClient.checkStatus(500, data: Data("{bad}".utf8))
        }
    }

    // MARK: - convert (end-to-end with the fake fetcher)

    @Test func convertReturnsMarkdownOnSuccess() async throws {
        let fetcher = FakeHTTPFetcher(body: try json(["document": ["md_content": "# Hi"], "errors": []]))
        let md = try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        #expect(md == "# Hi")
    }

    @Test func convertThrowsEndpointInvalidWhenBlank() async throws {
        let blank = DoclingServeClient(endpoint: "   ", fetcher: FakeHTTPFetcher(body: "x"))
        await #expect(throws: DoclingServeClient.Error.endpointInvalid("   ")) {
            try await blank.convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertThrowsUnauthorizedOn401() async throws {
        let fetcher = FakeHTTPFetcher(body: Data("forbidden".utf8), statusCode: 401)
        await #expect(throws: DoclingServeClient.Error.unauthorized) {
            try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    @Test func convertWrapsTransportError() async throws {
        // Empty fake queue → queueExhausted, wrapped as a Docling error (.network).
        let fetcher = FakeHTTPFetcher(responses: [])
        await #expect(throws: DoclingServeClient.Error.self) {
            try await client(fetcher).convert(pdfData: pdf, filename: "p.pdf", onProgress: nil)
        }
    }

    // MARK: - verifyConnection

    @Test func verifyConnectionSucceedsOn200() async throws {
        let fetcher = FakeHTTPFetcher(body: Data("{}".utf8))
        try await client(fetcher).verifyConnection()
    }

    @Test func verifyConnectionThrowsUnauthorizedOn401() async throws {
        let fetcher = FakeHTTPFetcher(body: Data("forbidden".utf8), statusCode: 401)
        await #expect(throws: DoclingServeClient.Error.unauthorized) {
            try await client(fetcher).verifyConnection()
        }
    }

    @Test func verifyConnectionThrowsEndpointInvalidWhenBlank() async throws {
        let blank = DoclingServeClient(endpoint: "   ", fetcher: FakeHTTPFetcher(body: "x"))
        await #expect(throws: DoclingServeClient.Error.endpointInvalid("   ")) {
            try await blank.verifyConnection()
        }
    }

    // MARK: - readiness / displayName

    @Test func readinessNeedsSetupWhenEndpointBlank() async {
        let r = await DoclingServeClient(endpoint: "  ", fetcher: FakeHTTPFetcher(body: "x")).readiness()
        if case .needsSetup = r { } else { Issue.record("expected .needsSetup") }
    }

    @Test func readinessReadyWhenEndpointSet() async {
        let r = await client(FakeHTTPFetcher(body: "x")).readiness()
        #expect(r == .ready)
    }

    @Test func displayNameIncludesHost() {
        #expect(client(FakeHTTPFetcher(body: "x")).displayName == "Docling Serve (localhost)")
        #expect(DoclingServeClient(endpoint: "garbage", fetcher: FakeHTTPFetcher(body: "x")).displayName == "Docling Serve")
    }
}
