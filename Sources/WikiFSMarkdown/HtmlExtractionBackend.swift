import Foundation

/// An HTML→Markdown extraction backend — the user's chosen engine for turning a
/// raw HTML source into readable markdown. Persisted in `extraction-config.json`
/// as a route selection record (issue #799 made extraction a manual trigger;
/// issue #1380 superseded that for package-selected HTML: when the effective
/// selection is the reviewed Defuddle package, ingestion converts
/// automatically — bundled route data `routeAutoExtraction` — and a removed
/// package lands the source verbatim. Built-in floors never convert at
/// import).
///
/// Mirrors `ExtractionBackend` (PDF) for parity, but is intentionally a
/// **separate** type rather than folded in: the input space differs (HTML bytes
/// vs PDF bytes), the conformer protocols differ (`HtmlMarkdownExtractor` vs
/// `MarkdownExtractor`), and the available engines have no overlap (there is no
/// `defuddle` for PDFs and no `pdf2md` for HTML). One typed enum per content
/// type keeps the Settings UI and the trigger paths honest — you can't ask the
/// PDF extractor to handle HTML by mistake.
///
/// A missing route selection stays a valid state: a config file written
/// before route records existed resolves no stored record, and the fresh-install
/// posture is now the bundled default route (the reviewed Defuddle package,
/// issue #1380) rather than a prompt. The asymmetry with PDF's non-optional
/// `backend: ExtractionBackend` remains deliberate: an unavailable Defuddle
/// package blocks the route (the source lands verbatim and the Extract
/// button surfaces the error) instead of substituting another engine — there
/// is no always-available fallback on par with `.localPdf2md`, because
/// `tagBased` quality varies by site and is a user choice, not a floor.
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
