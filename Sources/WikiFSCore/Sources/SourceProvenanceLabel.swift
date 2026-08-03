import Foundation
import WikiFSTypes

/// Pure two-dimensional provenance label helpers (provider × content type) for
/// `SourceDetailView`'s inline origin tag. The label combines
/// `"{provider} / {content type}"` unless the content type is unrecognized —
/// in which case it collapses to just the provider label.
///
/// Two-dimensional provenance surfaces BOTH where a source came from AND what
/// it is: a `.mmd` file dragged in reads "File / Mermaid" (was just "File"),
/// a `.pdf` from Zotero reads "Zotero / PDF", a markdown-folder import reads
/// "Folder / Markdown", while a YouTube source with no derivable content type
/// reads just "YouTube". Issue #644.
///
/// No provider is assumed to imply a content type — the suffix is always
/// derived from the actual file extension / MIME type of the stored source.
/// This means a website that served a PDF reads "Website / PDF", and a
/// markdown-folder source reads "Folder / Markdown" (not just "Folder").
///
/// Pure + unit-tested; the view threads in the resolved provider label, file
/// extension, and MIME type.
public enum SourceProvenanceLabel {

    // MARK: - Content type

    /// The display label for a source's content type, derived from its
    /// lowercased file extension (falling back to its MIME type when the
    /// extension is unrecognized). `nil` for unrecognized types so callers can
    /// omit the suffix and show just the provider.
    ///
    /// `ext` is the lowercased extension with no leading dot (matches
    /// `SourceSummary.ext`); passing `nil` / empty falls through to the
    /// MIME-type arm. Matching is case-insensitive on both paths.
    public static func contentTypeLabel(ext: String?, mimeType: String?) -> String? {
        switch (ext ?? "").lowercased() {
        case "mmd", "mermaid": return "Mermaid"
        case "pdf":            return "PDF"
        case "md", "markdown": return "Markdown"
        default: break
        }
        // Extension didn't map — fall back to MIME for sources whose ext was
        // lost or never set (e.g. a `text/markdown` row stored without an ext).
        if MimeType.isPDF(mimeType) { return "PDF" }
        if MimeType.isMarkdown(mimeType) { return "Markdown" }
        if MimeType.isMermaid(mimeType) { return "Mermaid" }
        return nil
    }

    // MARK: - Combined label

    /// The combined `"{provider} / {content type}"` label, or just `provider`
    /// when the content type is unrecognized. Issue #644.
    ///
    /// No provider is assumed to imply a content type — the suffix is always
    /// derived from `ext` / `mimeType`. A website source stored as markdown
    /// reads "Website / Markdown"; a website that served a PDF reads
    /// "Website / PDF"; a YouTube source with no derivable ext reads just
    /// "YouTube".
    ///
    /// - Parameters:
    ///   - provider: The human-facing provider label already resolved by the
    ///     caller (e.g. "File", "Zotero", "YouTube", "Website") — this helper
    ///     does NOT map agent names to provider labels, since `SourceDetailView`
    ///     already owns that switch (and uses different labels than
    ///     `SourceOrigin.displayLabel`, e.g. "Folder" vs "Markdown folder").
    ///   - ext: The source's lowercased file extension (no leading dot).
    ///   - mimeType: The source's MIME type (optional).
    public static func combine(
        provider: String,
        ext: String?,
        mimeType: String?
    ) -> String {
        guard let contentType = contentTypeLabel(ext: ext, mimeType: mimeType) else {
            return provider
        }
        return "\(provider) / \(contentType)"
    }
}
