import Foundation
import WikiFSTypes

/// Pure two-dimensional provenance label helpers (provider × content type) for
/// `SourceDetailView`'s inline origin tag. The label combines
/// `"{provider} / {content type}"` unless the provider already implies the
/// content type (YouTube → video, Website → page, Apple Podcast → audio,
/// markdown folder → markdown) or the content type is unrecognized — in which
/// case it collapses to just the provider label.
///
/// Two-dimensional provenance surfaces BOTH where a source came from AND what
/// it is: a `.mmd` file dragged in reads "File / Mermaid" (was just "File"),
/// a `.pdf` from Zotero reads "Zotero / PDF", while a YouTube URL still reads
/// just "YouTube" (the content type is implied). Issue #644.
///
/// Pure + unit-tested; the view threads in the resolved agent name, file
/// extension, and MIME type. Mirrors `MermaidSourceDetector`'s shape.
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

    // MARK: - Provider implication

    /// Whether a provider agent name implies a single content type, so the
    /// content-type suffix can be omitted from the combined label.
    ///
    /// URL-based media/web providers (YouTube, Vimeo, Spotify, SoundCloud,
    /// Website, Apple Podcast, remote-media) always serve one kind of content
    /// (video / audio / web page), and a markdown folder is by definition
    /// markdown. File and Zotero imports can carry anything, so they keep the
    /// suffix. Issue #644.
    public static func providerImpliesContentType(_ agentName: String) -> Bool {
        switch agentName {
        case "website", "markdown-folder", "apple-podcast",
             "youtube", "vimeo", "spotify", "soundcloud", "remote-media":
            return true
        default:
            return false
        }
    }

    // MARK: - Combined label

    /// The combined `"{provider} / {content type}"` label, or just `provider`
    /// when the provider implies the content type or the content type is
    /// unrecognized. Issue #644.
    ///
    /// - Parameters:
    ///   - provider: The human-facing provider label already resolved by the
    ///     caller (e.g. "File", "Zotero", "YouTube") — this helper does NOT
    ///     map agent names to provider labels, since `SourceDetailView`
    ///     already owns that switch (and uses different labels than
    ///     `SourceOrigin.displayLabel`, e.g. "Folder" vs "Markdown folder").
    ///   - agentName: The transport agent name from `SourceOrigin` — used to
    ///     decide whether the suffix is redundant.
    ///   - ext: The source's lowercased file extension (no leading dot).
    ///   - mimeType: The source's MIME type (optional).
    public static func combine(
        provider: String,
        agentName: String,
        ext: String?,
        mimeType: String?
    ) -> String {
        if providerImpliesContentType(agentName) { return provider }
        guard let contentType = contentTypeLabel(ext: ext, mimeType: mimeType) else {
            return provider
        }
        return "\(provider) / \(contentType)"
    }
}
