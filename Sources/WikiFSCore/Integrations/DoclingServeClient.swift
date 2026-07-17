import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The remote extraction backend: POSTs the PDF to a self-hosted Docling Serve
/// instance's `/v1/convert/file` endpoint and returns its Markdown output. Raw
/// HTTP (multipart/form-data), mirroring `ZoteroClient` and
/// `AnthropicExtractionClient`'s fetcher-injected, pure-helper shape.
///
/// Docling Serve's v1 API: the file is uploaded as a multipart `files` part
/// alongside `to_formats=md` (and `from_formats=pdf`); the single-file JSON
/// response is `{ "document": { "md_content": "…" }, "errors": [] }`. We pull
/// `document.md_content`; if it's empty we surface whatever `errors` the server
/// reported. Authentication is opt-in on the server side (`DOCLING_SERVE_API
/// _KEY`); when set, requests carry `X-Api-Key`. No hard size limit (self-hosted).
public struct DoclingServeClient: MarkdownExtractor {
    public enum Error: LocalizedError, Equatable {
        case endpointInvalid(String)
        case unauthorized
        case httpStatus(Int, String)
        case decoding(String)
        case network(String)
        case emptyOutput
        case serverErrors([String])

        public var errorDescription: String? {
            switch self {
            case .endpointInvalid(let raw):
                return "The Docling Serve endpoint isn't a valid URL (got \"\(raw)\"). Set it in Settings → Extraction."
            case .unauthorized:
                return "Docling Serve rejected that API key. Check it in Settings → Extraction, or clear it if the server has no auth."
            case .httpStatus(let code, let detail):
                return "Docling Serve returned HTTP \(code)\(detail.isEmpty ? "" : ": \(detail)")."
            case .decoding(let msg):
                return "Couldn't read Docling Serve's response: \(msg)."
            case .network(let msg):
                return msg
            case .emptyOutput:
                return "Docling Serve returned no markdown for this PDF."
            case .serverErrors(let msgs):
                return "Docling Serve reported errors: \(msgs.joined(separator: "; "))."
            }
        }
    }

    public let endpoint: String
    public let apiToken: String?
    private let fetcher: any HTTPRequestFetcher

    public init(
        endpoint: String,
        apiToken: String? = nil,
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.endpoint = endpoint
        self.apiToken = apiToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.fetcher = fetcher
    }

    public var displayName: String {
        if let host = URLComponents(string: endpoint)?.host, !host.isEmpty {
            return "Docling Serve (\(host))"
        }
        return "Docling Serve"
    }

    public func readiness() async -> ExtractionReadiness {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .needsSetup("Set a Docling Serve endpoint in Settings → Extraction (default \(ExtractionConfig.defaultDoclingServeEndpoint)).")
            : .ready
    }

    public func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.endpointInvalid(endpoint)
        }

        onProgress?("Sending \(filename) (\(pdfData.count / 1024) KB) to \(displayName)…\n")
        let request = try Self.buildRequest(
            endpoint: endpoint, apiToken: apiToken, filename: filename, pdfData: pdfData)
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.network("Couldn't reach Docling Serve: \(error.localizedDescription)")
        }
        try Self.checkStatus(status, data: data)

        let markdown = try Self.decode(data: data)
        onProgress?("Done — \(markdown.count) chars of markdown.\n")
        return markdown
    }

    /// Minimal connectivity + auth probe: `GET <endpoint>/openapi.json` (FastAPI's
    /// standard schema endpoint). 200 → the service is up at this base URL;
    /// 401/403 → the `X-Api-Key` is wrong. Used by `ExtractionSettingsView`'s
    /// Test Connection. Doesn't run a conversion, so it's cheap and PDF-free.
    public func verifyConnection() async throws {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.endpointInvalid(endpoint)
        }
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/openapi.json") else {
            throw Error.endpointInvalid(endpoint)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let apiToken, !apiToken.isEmpty {
            request.setValue(apiToken, forHTTPHeaderField: "X-Api-Key")
        }
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch {
            throw Error.network("Couldn't reach Docling Serve: \(error.localizedDescription)")
        }
        try Self.checkStatus(status, data: data)
    }

    // MARK: - Pure helpers (unit-test targets — no network)

    /// Build the `POST <endpoint>/v1/convert/file` multipart request: the PDF
    /// as the `files` part plus `to_formats=md` / `from_formats=pdf` fields, an
    /// optional `X-Api-Key` when auth is configured. A fresh boundary per call.
    public static func buildRequest(
        endpoint: String, apiToken: String?, filename: String, pdfData: Data
    ) throws -> URLRequest {
        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/v1/convert/file") else {
            throw Error.endpointInvalid(endpoint)
        }

        let boundary = "----WikiFSBoundary\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiToken, !apiToken.isEmpty {
            request.setValue(apiToken, forHTTPHeaderField: "X-Api-Key")
        }
        request.httpBody = buildMultipartBody(
            boundary: boundary, filename: filename, pdfData: pdfData)
        return request
    }

    /// Map a non-2xx status to the typed error. 401/403 → `unauthorized`
    /// (wrong/missing `X-Api-Key`); everything else → `.httpStatus` with a
    /// short body excerpt.
    public static func checkStatus(_ status: Int, data: Data) throws {
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
                .description ?? ""
            switch status {
            case 401, 403: throw Error.unauthorized
            default: throw Error.httpStatus(status, detail)
            }
        }
    }

    /// Pull `document.md_content` from the single-file JSON response. With
    /// `abort_on_error=false` (Docling's default) the server may still return
    /// partial output alongside `errors`; we return the markdown when it's
    /// non-empty and only throw `serverErrors` / `emptyOutput` when it isn't.
    public static func decode(data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.decoding("not a JSON object")
        }
        let md = (obj["document"] as? [String: Any])?["md_content"] as? String
        if let md, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return md
        }
        // No usable markdown — surface whatever the server told us went wrong.
        if let errors = obj["errors"] as? [Any], !errors.isEmpty {
            let msgs = errors.compactMap(Self.errorMessage)
            if !msgs.isEmpty { throw Error.serverErrors(msgs) }
        }
        throw Error.emptyOutput
    }

    /// Docling's `errors[]` entries are `{component, error_message}` dicts (and
    /// occasionally bare strings); extract a human-readable line either way.
    private static func errorMessage(_ any: Any) -> String? {
        if let s = any as? String { return s }
        if let dict = any as? [String: Any], let msg = dict["error_message"] as? String {
            return msg
        }
        return nil
    }

    /// Assemble the multipart/form-data body: two scalar fields then the file
    /// part. Uses CRLF line endings (RFC 7578). Fields named to match Docling
    /// Serve's documented `to_formats` / `from_formats` / `files` parameters.
    public static func buildMultipartBody(
        boundary: String, filename: String, pdfData: Data
    ) -> Data {
        var body = Data()
        appendField("to_formats", "md", boundary: boundary, to: &body)
        appendField("from_formats", "pdf", boundary: boundary, to: &body)
        appendString("--\(boundary)\r\n", to: &body)
        appendString(
            "Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n",
            to: &body)
        appendString("Content-Type: application/pdf\r\n\r\n", to: &body)
        body.append(pdfData)
        appendString("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func appendString(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
    }

    private static func appendField(
        _ name: String, _ value: String, boundary: String, to data: inout Data
    ) {
        appendString("--\(boundary)\r\n", to: &data)
        appendString(
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", to: &data)
        appendString("\(value)\r\n", to: &data)
    }
}

private extension String {
    /// Empty/whitespace-only string → nil (so `apiToken` normalizes to "unset").
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
