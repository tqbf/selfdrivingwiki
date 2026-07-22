import Foundation

/// An HTML→Markdown extraction backend — the user's chosen engine for turning a
/// raw HTML source into readable markdown. Persisted in `extraction-config.json`
/// as `ExtractionConfig.htmlBackend` (issue #799: no auto-extraction at ingest —
/// the user picks a backend and triggers extraction explicitly).
///
/// Mirrors `ExtractionBackend` (PDF) for parity, but is intentionally a
/// **separate** type rather than folded in: the input space differs (HTML bytes
/// vs PDF bytes), the conformer protocols differ (`HtmlMarkdownExtractor` vs
/// `MarkdownExtractor`), and the available engines have no overlap (there is no
/// `defuddle` for PDFs and no `pdf2md` for HTML). One typed enum per content
/// type keeps the Settings UI and the trigger paths honest — you can't ask the
/// PDF extractor to handle HTML by mistake.
///
/// `nil` (no backend chosen yet) is a valid state: a fresh install, or a config
/// file written before this field existed, decodes `htmlBackend` as nil and the
/// UI prompts the user to pick one before the first extraction. This is the
/// deliberate asymmetry with PDF's non-optional `backend: ExtractionBackend`
/// (which always falls back to `.localPdf2md`): HTML has no always-available
/// fallback engine — `defuddle` requires the bundled binary and `tagBased`
/// quality varies by site, so "no default" is the safer posture.
public enum HtmlExtractionBackend: String, CaseIterable, Sendable, Codable {
    /// The bundled `defuddle` binary (Readability-style article extraction with
    /// site-specific heuristics). Produces the highest-quality article markdown
    /// for well-structured pages (blogs, news, docs). Requires the defuddle
    /// binary at runtime; if missing, extraction falls back to `tagBased`.
    case defuddle
    /// The built-in tag-based converter (`HTMLToMarkdown.convert`) — no external
    /// dependency, runs everywhere. Lower fidelity on complex layouts (Sidebars,
    /// nav bars, cookie banners leak through), but always available.
    case tagBased

    /// A short label for the Settings picker and the Extract/Re-extract menu.
    public var displayName: String {
        switch self {
        case .defuddle: return "Defuddle (article extraction)"
        case .tagBased: return "Tag-based (built-in)"
        }
    }
}
