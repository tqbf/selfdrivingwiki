import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Gemini extraction backend: sends the PDF to Google's Gemini API via the
/// classic `generateContent` endpoint and returns the extracted Markdown. Raw
/// HTTP (no SDK), mirroring `ZoteroClient` / `AnthropicExtractionClient`'s
/// fetcher-injected, pure-helper shape.
///
/// PDF input is a base64 `inline_data` part; the response `candidates[0].
/// content.parts[].text` blocks are concatenated. Gemini's auth is a single
/// `x-goog-api-key` header (a Google AI Studio key — works on the free tier).
/// We use `generateContent`, not the newer Interactions API: its raw response is
/// a flat `candidates` array (trivial to parse), whereas Interactions returns an
/// agentic `steps` timeline that's overkill for a one-shot extract and is still
/// in beta with breaking changes. Default model `gemini-3.5-flash`.
public struct GeminiExtractionClient: MarkdownExtractor {
    public enum Error: LocalizedError, Equatable {
        case missingAPIKey
        case tooLarge(byteCount: Int)
        case unauthorized
        case httpStatus(Int, String)
        case decoding(String)
        case network(String)
        case blocked(String)
        case emptyOutput

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Gemini API key is set. Add one in Settings → Extraction."
            case .tooLarge(let n):
                // Gemini accepts PDFs up to 50 MB / 1000 pages (base64 inflates
                // ~1.33×, so guard raw bytes under the cap).
                return "PDF is too large for Gemini extraction (\(n / 1_000_000) MB; Gemini caps a PDF at 50 MB). Use Local pdf2md or Docling Serve."
            case .unauthorized:
                return "Gemini rejected that API key. Check it in Settings → Extraction."
            case .httpStatus(let code, let detail):
                return "Gemini returned HTTP \(code)\(detail.isEmpty ? "" : ": \(detail)")."
            case .decoding(let msg):
                return "Couldn't read Gemini's response: \(msg)"
            case .network(let msg):
                return msg
            case .blocked(let reason):
                return "Gemini blocked this PDF (\(reason)). Try again, or use Local pdf2md / Docling Serve."
            case .emptyOutput:
                return "Gemini returned no markdown for this PDF."
            }
        }
    }

    /// Gemini accepts PDFs up to 50 MB. Guard a hair under to leave room.
    public static let maxPDFBytes: Int = 48 * 1024 * 1024

    /// A generous output cap. Flash models support ≥64K output tokens.
    public static let maxOutputTokens: Int = 65_536

    public let model: String
    public let apiKey: String
    public let baseURL: URL
    private let fetcher: any HTTPRequestFetcher

    public init(
        model: String,
        apiKey: String,
        baseURL: URL = URL(string: ExtractionConfig.defaultGeminiBaseURL)!,
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fetcher = fetcher
    }

    public var displayName: String { "Gemini (\(model))" }

    public func readiness() async -> ExtractionReadiness {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .needsSetup("Add your Google AI Studio API key in Settings → Extraction.")
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

        onProgress?("Sending \(filename) (\(pdfData.count / 1024) KB) to Gemini (\(model))…\n")
        let request = try Self.buildRequest(
            pdfData: pdfData, model: model, apiKey: apiKey, baseURL: baseURL)
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.network("Couldn't reach Gemini: \(error.localizedDescription)")
        }
        try Self.checkStatus(status, data: data)

        let decoded = try Self.decode(data: data)
        if decoded.finishReason == "MAX_TOKENS" {
            onProgress?("Warning: response hit the token cap — markdown may be truncated.\n")
        }
        onProgress?("Done — \(decoded.markdown.count) chars of markdown.\n")
        return decoded.markdown
    }

    /// Minimal connectivity + auth probe: a 1-token `ping` (no PDF). 200 → key
    /// valid + reachable; 401/403 → key invalid. A bad key actually returns 400
    /// with "API key not valid", which surfaces via `.httpStatus` carrying that
    /// message — clear enough that Test Connection reads sensibly.
    public func verifyConnection() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingAPIKey
        }
        let url = try Self.endpointURL(model: model, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["role": "user", "parts": [["text": "ping"]]]],
            "generationConfig": ["maxOutputTokens": 1, "temperature": 0],
        ])
        let (data, status): (Data, Int)
        do {
            (data, status) = try await fetcher.fetch(request)
        } catch {
            throw Error.network("Couldn't reach Gemini: \(error.localizedDescription)")
        }
        try Self.checkStatus(status, data: data)
    }

    // MARK: - Pure helpers (unit-test targets — no network)

    /// `generateContent` endpoint URL: `<base>/v1beta/models/<model>:generateContent`.
    static func endpointURL(model: String, baseURL: URL) throws -> URL {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/v1beta/models/\(model):generateContent") else {
            throw Error.network("Invalid Gemini endpoint URL")
        }
        return url
    }

    /// Build the `generateContent` request with the PDF as a base64
    /// `inline_data` part + the shared extraction prompt.
    public static func buildRequest(
        pdfData: Data, model: String, apiKey: String, baseURL: URL
    ) throws -> URLRequest {
        let url = try endpointURL(model: model, baseURL: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let b64 = pdfData.base64EncodedString()
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": MimeType.pdf, "data": b64]],
                    ["text": ExtractionPrompts.instruction],
                ],
            ]],
            "systemInstruction": ["parts": [["text": ExtractionPrompts.system]]],
            "generationConfig": [
                "maxOutputTokens": maxOutputTokens,
                "temperature": 0,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Map a non-2xx status to the typed error. 401/403 → `unauthorized`;
    /// everything else → `.httpStatus` with a short body excerpt (a 400 "API key
    /// not valid" reads clearly via the carried detail).
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

    /// The decoded extraction: concatenated markdown + the candidate's
    /// `finishReason` (so the caller can warn on `MAX_TOKENS` truncation).
    public struct DecodedExtraction: Equatable {
        public let markdown: String
        public let finishReason: String?
    }

    /// Concatenate the first candidate's `content.parts[].text`. Throws
    /// `.blocked` on a prompt-level `blockReason` or a blocking `finishReason`
    /// with no text; `.emptyOutput` on no text; `.decoding` on a malformed body.
    public static func decode(data: Data) throws -> DecodedExtraction {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.decoding("not a JSON object")
        }
        // Prompt rejected before generation (SAFETY, etc.).
        if let feedback = obj["promptFeedback"] as? [String: Any],
           let blockReason = feedback["blockReason"] as? String, !blockReason.isEmpty {
            throw Error.blocked("prompt: \(blockReason)")
        }
        let candidates = obj["candidates"] as? [[String: Any]] ?? []
        let first = candidates.first
        let finishReason = first?["finishReason"] as? String
        let parts = (first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let markdown = parts.compactMap { $0["text"] as? String }.joined()

        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let finishReason, Self.isBlocking(finishReason) {
                throw Error.blocked("finish: \(finishReason)")
            }
            throw Error.emptyOutput
        }
        return DecodedExtraction(markdown: markdown, finishReason: finishReason)
    }

    /// `finishReason` values that mean generation was cut off for policy/recital
    /// reasons rather than completing normally or hitting the token cap.
    private static func isBlocking(_ reason: String) -> Bool {
        [
            "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT",
            "SPII", "OTHER", "IMAGE_SAFETY", "LANGUAGE",
        ].contains(reason)
    }
}
