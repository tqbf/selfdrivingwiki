import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The model extraction backend: sends the PDF to Claude via the Anthropic
/// Messages API and returns the extracted Markdown. Raw HTTP (no official Swift
/// SDK), mirroring `ZoteroClient`'s fetcher-injected, pure-helper shape.
///
/// PDF input is a base64 `document` content block (no beta header); the API limit
/// is a 32 MB request, so we reject oversized PDFs early with `.tooLarge` rather
/// than letting the API 413. The response `content[]` text blocks are
/// concatenated; a `stop_reason: "refusal"` or empty body is an error. Default
/// model `claude-sonnet-4-6` (the right cost/fidelity point for transcription),
/// user-overridable.
public struct AnthropicExtractionClient: MarkdownExtractor {
    public enum Error: LocalizedError, Equatable {
        case missingAPIKey
        case tooLarge(byteCount: Int)
        case unauthorized
        case httpStatus(Int, String)
        case decoding(String)
        case network(String)
        case refused
        case emptyOutput
        case truncated

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key is set. Add one in Settings → Extraction."
            case .tooLarge(let n):
                // Anthropic caps a request at 32 MB; a PDF whose bytes approach
                // that (base64 inflates ~1.33×) won't fit. Suggest the local or
                // Docling backend instead.
                return "PDF is too large for Claude extraction (\(n / 1_000_000) MB; the Anthropic API caps a request at 32 MB). Use Local pdf2md or Docling Serve."
            case .unauthorized:
                return "Anthropic rejected that API key. Check it in Settings → Extraction."
            case .httpStatus(let code, let detail):
                return "Anthropic returned HTTP \(code)\(detail.isEmpty ? "" : ": \(detail)")."
            case .decoding(let msg):
                return "Couldn't read Anthropic's response: \(msg)"
            case .network(let msg):
                return msg
            case .refused:
                return "Claude declined to process this PDF. Try again, or use Local pdf2md / Docling Serve."
            case .emptyOutput:
                return "Claude returned no markdown for this PDF."
            case .truncated:
                return "Claude's response hit the token cap and may be truncated."
            }
        }
    }

    /// Anthropic caps a single request at 32 MB. base64 of the PDF inflates it
    /// ~1.33×, so guard the raw bytes a bit under that to leave room for the
    /// request envelope and prompt.
    public static let maxPDFBytes: Int = 24 * 1024 * 1024

    /// A generous output cap that every current model supports (Sonnet 4.6 caps
    /// at 64K output; Opus can do 128K). Non-streaming with a long
    /// `URLSessionRequestFetcher` timeout handles this fine for typical PDFs.
    public static let maxTokens: Int = 64_000

    public let model: String
    public let apiKey: String
    public let baseURL: URL
    private let fetcher: any HTTPRequestFetcher

    public init(
        model: String,
        apiKey: String,
        baseURL: URL = URL(string: ExtractionConfig.defaultAnthropicBaseURL)!,
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fetcher = fetcher
    }

    public var displayName: String { "Claude (\(model))" }

    public func readiness() async -> ExtractionReadiness {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .needsSetup("Add your Anthropic API key in Settings → Extraction.")
            : .ready
    }

    public func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingAPIKey
        }
        guard pdfData.count <= Self.maxPDFBytes else {
            throw Error.tooLarge(byteCount: pdfData.count)
        }

        onProgress?("Sending \(filename) (\(pdfData.count / 1024) KB) to Claude (\(model))…\n")
        let request = try Self.buildRequest(
            pdfData: pdfData, model: model, apiKey: apiKey, baseURL: baseURL)
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.network("Couldn't reach Anthropic: \(error.localizedDescription)")
        }
        try Self.checkStatus(status, data: data)

        let decoded = try Self.decode(data: data)
        if decoded.stopReason == "max_tokens" {
            onProgress?("Warning: response hit the token cap — markdown may be truncated.\n")
        }
        onProgress?("Done — \(decoded.markdown.count) chars of markdown.\n")
        return decoded.markdown
    }

    /// Minimal connectivity + auth probe: a 1-token `ping` message. A 200 means
    /// the key is valid and the endpoint is reachable; 401 → `.unauthorized`.
    /// Used by `ExtractionSettingsView`'s Test Connection. Negligible cost (one
    /// output token); reuses `checkStatus` so non-2xx maps to the typed errors.
    public func verifyConnection() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingAPIKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ])
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch {
            throw Error.network("Couldn't reach Anthropic: \(error.localizedDescription)")
        }
        try Self.checkStatus(status, data: data)
    }

    // MARK: - Pure helpers (unit-test targets — no network)

    /// Build the `POST /v1/messages` request with the PDF as a base64 document
    /// block + the extraction prompt. Returns the request (body + headers).
    public static func buildRequest(
        pdfData: Data, model: String, apiKey: String, baseURL: URL
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // base64EncodedString() with no options yields a single line — the API
        // rejects base64 with embedded newlines.
        let b64 = pdfData.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": extractionSystemPrompt,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "document",
                        "source": [
                            "type": "base64",
                            "media_type": "application/pdf",
                            "data": b64,
                        ],
                    ],
                    ["type": "text", "text": extractionUserInstruction],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Map a non-2xx status to the typed error. `unauthorized` (401) and
    /// `tooLarge`-style 413 get specific cases; everything else is
    /// `.httpStatus(code, detail)` with a short body excerpt.
    public static func checkStatus(_ status: Int, data: Data) throws {
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(300)
                .description ?? ""
            switch status {
            case 401: throw Error.unauthorized
            default: throw Error.httpStatus(status, detail)
            }
        }
    }

    /// The decoded extraction: the concatenated markdown plus the response's
    /// `stop_reason` (so the caller can warn on `max_tokens` truncation).
    public struct DecodedExtraction: Equatable {
        public let markdown: String
        public let stopReason: String?
    }

    /// Concatenate the response `content[]` text blocks. Throws `.refused` on a
    /// `stop_reason: "refusal"`, `.emptyOutput` on no text, `.decoding` on a
    /// malformed body.
    public static func decode(data: Data) throws -> DecodedExtraction {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.decoding("not a JSON object")
        }
        let stopReason = obj["stop_reason"] as? String
        if stopReason == "refusal" {
            throw Error.refused
        }
        let content = obj["content"] as? [[String: Any]] ?? []
        let texts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        let markdown = texts.joined()
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyOutput
        }
        return DecodedExtraction(markdown: markdown, stopReason: stopReason)
    }

    /// Faithful-transcription system prompt — the shared contract in
    /// `ExtractionPrompts.system`. Kept as an alias so call sites read naturally.
    public static let extractionSystemPrompt = ExtractionPrompts.system

    public static let extractionUserInstruction = ExtractionPrompts.instruction
}
