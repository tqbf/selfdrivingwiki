import Foundation

/// Canonical MIME-type constants and typed predicates.
///
/// Centralizes the literals that were previously compared inline across the
/// codebase (`"application/pdf"`, `hasPrefix("text/")`, the `application/octet-stream`
/// fallback, the Markdown variants, etc.). Routing every comparison, prefix
/// check, and switch label through here keeps the canonical strings in one
/// place — a typo like `"application/pdf "` can no longer silently mis-guard,
/// because a single typo'd call site just becomes a compile-time mismatch.
///
/// All matching is case-insensitive, per RFC 2045. New stored values pass
/// through `ContentTypeDetector.normalizeMIMEType` before persistence.
/// Predicates still accept mixed case for legacy and external values.
///
/// This type stays in the shared `WikiFSTypes` leaf target. Link rendering and
/// core ingestion can share these MIME constants without a dependency cycle.
public enum MimeType {

    // MARK: - Constants

    /// `application/pdf`.
    public static let pdf = "application/pdf"

    /// `application/octet-stream` — the generic binary catch-all / fallback.
    public static let octetStream = "application/octet-stream"

    /// `text/markdown`.
    public static let markdown = "text/markdown"

    /// `text/x-markdown`.
    public static let markdownX = "text/x-markdown"

    /// `text/html`.
    public static let html = "text/html"

    /// `text/mermaid` — the conventional MIME type for a standalone Mermaid
    /// diagram source (`.mmd`).
    public static let mermaid = "text/mermaid"

    /// `text/x-mermaid` — the `x-` variant some tools emit for Mermaid sources.
    public static let mermaidX = "text/x-mermaid"

    /// `application/json` — JSON Canvas files use JSON as their registered
    /// media type. The `.canvas` extension remains the format discriminator.
    public static let json = "application/json"

    /// `application/xhtml+xml`.
    public static let xhtml = "application/xhtml+xml"

    /// `image/jpeg`.
    public static let imageJPEG = "image/jpeg"

    /// `video/youtube` — the synthetic embed type used by `ExternalEmbed`.
    public static let videoYouTube = "video/youtube"

    // MARK: - Sets / prefixes

    /// Prefix shared by every `text/*` type.
    public static let textPrefix = "text/"

    /// The recognized Markdown MIME variants (`text/markdown`, `text/x-markdown`).
    public static let markdownVariants: Set<String> = [markdown, markdownX]

    /// The recognized Mermaid MIME variants (`text/mermaid`, `text/x-mermaid`).
    public static let mermaidVariants: Set<String> = [mermaid, mermaidX]

    // MARK: - Predicates

    /// Whether `mime` is `application/pdf` (case-insensitive). `nil` is `false`.
    public static func isPDF(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.lowercased() == pdf
    }

    /// Whether `mime` is any `text/*` type (case-insensitive prefix). `nil` is `false`.
    public static func isText(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.lowercased().hasPrefix(textPrefix)
    }

    /// Whether `mime` is one of the recognized Markdown variants
    /// (`text/markdown` / `text/x-markdown`, case-insensitive). `nil` is `false`.
    public static func isMarkdown(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return markdownVariants.contains(mime.lowercased())
    }

    /// Whether `mime` is one of the recognized Mermaid variants
    /// (`text/mermaid` / `text/x-mermaid`, case-insensitive). `nil` is `false`.
    public static func isMermaid(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mermaidVariants.contains(mime.lowercased())
    }

    /// Extension-derived MIME for known text-by-extension cases that
    /// `UTType.preferredMIMEType` cannot resolve (it returns a dynamic UTI tag
    /// for unregistered extensions like `.mmd`, and `nil` for its MIME).
    ///
    /// This is the last-resort fallback in `GRDBWikiStore.addSource`'s MIME
    /// chain — without it, a standalone `.mmd` Mermaid source ingests with
    /// `mime_type = NULL`, which breaks `SourceDetailView.isMarkdownNative`
    /// (`MimeType.isText(nil) == false`) and leaves every Mermaid tab empty
    /// (issue #620). The canonical extension string is
    /// `MermaidSourceDetector.mermaidExtension` (kept here as a literal because
    /// `WikiFSTypes` can't depend on `WikiFSCore`).
    ///
    /// Lowercased input is assumed (callers lower-case extensions); the switch
    /// is case-insensitive anyway. Returns `nil` for unrecognized extensions.
    public static func mime(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "mmd", "mermaid": return mermaid
        case "canvas": return json
        default: return nil
        }
    }
}
