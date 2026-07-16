import Foundation

/// A PDF→Markdown extraction backend — the engine behind the "Extract Markdown"
/// action and the ingest-path PDF conversion. Concrete backends: local pdf2md
/// (subprocess), a model API (Anthropic Messages), or a remote service (Docling
/// Serve). Every backend returns a markdown `String` the caller stores verbatim
/// as a `source_markdown_versions` row with origin `"extraction"`; the storage
/// path is backend-agnostic, so adding a backend touches only this protocol and
/// the coordinator (plans/pdf-extraction-backends.md).
///
/// `convert` reports human-readable progress lines through `onProgress` (the
/// transcript sidebar's conversion box). There is deliberately no `onStart(pid:)`
/// hook: only the subprocess backend has a PID, and it reports it via
/// `onProgress`. Remote/model backends have nothing analogous, and the UI already
/// nil-handles the PID ("Converting…" fallback).
public protocol MarkdownExtractor: Sendable {
    /// A short label for logs and the conversion-box header, e.g.
    /// "Local pdf2md", "Claude (Opus 4.8)", "Docling Serve".
    var displayName: String { get }

    /// A cheap probe run before `convert`. `.ready` means proceed;
    /// `.needsSetup` / `.notInstalled` carry a user-facing reason the UI shows
    /// (and, for the local backend, offers the dependency download).
    func readiness() async -> ExtractionReadiness

    /// Convert PDF bytes to Markdown. Throws on any failure; the caller catches
    /// and surfaces the message. `onProgress` is invoked off the main actor with
    /// incremental status lines (may be nil).
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String
}

/// The result of a backend's readiness probe.
public enum ExtractionReadiness: Sendable, Equatable {
    /// Ready to convert now.
    case ready
    /// The backend is selected but unconfigured — e.g. no Anthropic API key, no
    /// Docling Serve endpoint. The associated string is shown to the user and
    /// points them at Settings.
    case needsSetup(String)
    /// The local backend's dependencies aren't installed yet (the ~2 GB
    /// docling/granite download). The UI offers the download.
    case notInstalled(String)

    /// `true` only for `.ready`.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// The user's chosen extraction backend, persisted in `extraction-config.json`
/// (the single source of truth — `ExtractionSettingsView`'s picker binds to a
/// draft saved on Save, and `ExtractionCoordinator.current()` reads it).
/// `ExtractionCoordinator.current()` maps this + config + Keychain to a concrete
/// `MarkdownExtractor`.
public enum ExtractionBackend: String, Sendable, CaseIterable, Codable {
    /// The bundled `tools/pdf2md` subprocess (docling + granite-docling VLM).
    case localPdf2md
    /// Delegate PDF extraction to a user-configured ACP provider (Claude,
    /// Gemini, Hermes, Copilot, …). Reuses the provider's Keychain API key
    /// from `ACPCredentialStore` — no second secret. The PDF is written to a
    /// temp file and the configured ACP agent reads it via its native file
    /// tooling, then returns markdown. This is the recommended backend: it
    /// works with ANY ACP provider, not just Claude/Gemini.
    case acp
    /// Claude via the Anthropic Messages API (PDF `document` block + extraction prompt).
    case anthropic
    /// Gemini via the Google AI generateContent API (PDF `inline_data` part).
    case gemini
    /// A self-hosted Docling Serve HTTP service.
    case doclingServe

    /// A short label for the Settings picker.
    public var displayName: String {
        switch self {
        case .localPdf2md: return "Local pdf2md"
        case .acp: return "ACP Provider"
        case .anthropic: return "Claude (Anthropic API)"
        case .gemini: return "Gemini (Google AI)"
        case .doclingServe: return "Docling Serve"
        }
    }

    /// A one-line description of what each backend is, for the picker's help row.
    public var helpText: String {
        switch self {
        case .localPdf2md:
            return "On-device via the bundled pdf2md (docling + granite VLM). Private; needs a one-time ~2 GB download."
        case .acp:
            return "Send the PDF to your configured ACP provider (Claude, Gemini, Hermes, …). Reuses the API key from Settings → Agents — no separate credentials. The PDF leaves your Mac."
        case .anthropic:
            return "Send the PDF to Claude and get markdown back. Needs an Anthropic API key; the PDF leaves your Mac."
        case .gemini:
            return "Send the PDF to Gemini and get markdown back. Needs a Google AI Studio API key; has a free tier; the PDF leaves your Mac."
        case .doclingServe:
            return "A self-hosted Docling Serve instance. Private to your network; needs an endpoint URL."
        }
    }

    /// The PROV `agents.name` this backend maps to (§4.7). Used by
    /// `recordMarkdownExtraction` so an extraction's provenance recovers to the
    /// backend that produced it. Stable strings, never user-facing.
    public var agentName: String {
        switch self {
        case .localPdf2md: return "pdf2md"
        case .acp: return "acp-extraction"
        case .anthropic:   return "claude"
        case .gemini:      return "gemini"
        case .doclingServe: return "docling-serve"
        }
    }

    /// Reverse of `agentName`: resolve the backend that produced an extraction
    /// from its PROV agent name. Returns nil for `"legacy-extraction"` (pre-v21
    /// rows) and any unknown agent — callers fall back to a "Legacy"/raw label.
    public static func from(agentName: String) -> ExtractionBackend? {
        switch agentName {
        case ExtractionBackend.localPdf2md.agentName: return .localPdf2md
        case ExtractionBackend.acp.agentName:          return .acp
        case ExtractionBackend.anthropic.agentName:   return .anthropic
        case ExtractionBackend.gemini.agentName:      return .gemini
        case ExtractionBackend.doclingServe.agentName: return .doclingServe
        default: return nil
        }
    }
}

/// The shared extraction contract: a faithful-transcription prompt every model
/// backend uses so output is consistent regardless of provider. Both
/// `AnthropicExtractionClient` and `GeminiExtractionClient` send these verbatim.
public enum ExtractionPrompts {
    /// System instruction: a precise PDF→Markdown transcription engine. Output
    /// ONLY markdown, preserve structure/tables/math, no commentary.
    public static let system: String = GeneratedPrompts.extractionSystem

    /// The per-request instruction paired with the PDF input.
    public static let instruction: String = GeneratedPrompts.extractionInstruction
}
