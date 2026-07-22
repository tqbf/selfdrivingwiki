import Foundation

/// The markdown + metadata an HTML extractor (defuddle by default) produces.
/// Carried alongside the original HTML bytes (issue #599 two-layer model) and
/// written as a `.extraction`-origin processed-markdown version.
///
/// Issue #799 PR2: this type, the `HtmlMarkdownExtractor` protocol below, and
/// the `TagBasedHtmlExtractor` conformer in `HTMLToMarkdown.swift` now live in
/// `WikiFSMarkdown` (alongside the PDF `MarkdownExtractor` / `ExtractionBackend`
/// siblings). Previously they lived in `WikiFSCore/Sources/FormatMaterializer.swift`;
/// moved so `WikiFSMarkdown/HTMLToMarkdown.swift` can host the always-available
/// conformer without a circular dependency. `WikiFSCore` re-exports
/// `WikiFSMarkdown` via `@_exported import`, so all existing callers that
/// `import WikiFSCore` continue to see these types unchanged.
public struct HtmlExtractionResult: Sendable {
    public let markdown: String
    public let title: String?
    public let author: String?
    public let description: String?
    public let published: String?
    public let wordCount: Int?

    public init(
        markdown: String,
        title: String? = nil,
        author: String? = nil,
        description: String? = nil,
        published: String? = nil,
        wordCount: Int? = nil
    ) {
        self.markdown = markdown
        self.title = title
        self.author = author
        self.description = description
        self.published = published
        self.wordCount = wordCount
    }
}

/// Injectable HTML→Markdown extractor (defuddle by default). The protocol lives
/// in `WikiFSMarkdown` so the always-available conformer (`TagBasedHtmlExtractor`
/// in `HTMLToMarkdown.swift`) can sit alongside `HTMLToMarkdown`. The
/// AppKit-coupled defuddle conformer (`LocalDefuddleExtractor` in
/// `Sources/WikiFS/Sources/DefuddleExtractionService.swift`) lives in the WikiFS
/// app target and is injected via a factory closure at app wiring time —
/// mirroring the `MarkdownExtractor` / `LocalPdf2MarkdownExtractor` pattern.
public protocol HtmlMarkdownExtractor: Sendable {
    /// Extract article markdown + metadata from HTML. Best-effort: returns nil
    /// on any failure (binary missing, SPA/empty body, bad JSON) so the caller
    /// falls back to tag-based `HTMLToMarkdown`.
    func extract(html: String) async -> HtmlExtractionResult?
}
