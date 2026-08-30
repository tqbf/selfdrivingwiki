import Foundation

/// The markdown + warnings a DOCX extractor (the reviewed docx2md package)
/// produces from one Word document. Carried alongside the original `.docx`
/// bytes and written as an `.extraction`-origin processed-markdown version —
/// the same two-layer model as the HTML path (issue #599).
///
/// Embedded images are NOT extracted in v1: the markdown carries
/// `![Figure N](figure-N.png)` placeholders instead, and `warnings` reports
/// how many images were skipped. mammoth's conversion messages (style
/// fallbacks, unsupported elements) surface here too so the extraction
/// report stays honest about fidelity loss.
public struct DocxExtractionResult: Sendable {
    public let markdown: String
    /// mammoth conversion messages + the image-placeholder warning. Bounded
    /// by the package protocol (≤128 entries, ≤1,024 bytes each).
    public let warnings: [String]

    public init(markdown: String, warnings: [String] = []) {
        self.markdown = markdown
        self.warnings = warnings
    }
}

/// The DOCX sibling of `HtmlMarkdownExtractor`. There is no built-in Swift
/// conformer — DOCX extraction is package-only (the reviewed docx2md
/// package, running in a managed `bun` process), so unlike HTML there is no
/// tag-based fallback. Reviewed package adapters conform to this protocol in
/// `WikiFSEngine`.
public protocol DocxMarkdownExtractor: Sendable {
    /// Convert a `.docx` payload to Markdown. Best-effort: returns nil on any
    /// failure (runtime missing, unparseable OOXML, empty conversion) so the
    /// caller records the extraction attempt as failed rather than writing a
    /// partial result.
    func extract(docx: Data) async -> DocxExtractionResult?
}
