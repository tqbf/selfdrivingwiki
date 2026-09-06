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

    /// `application/vnd.openxmlformats-officedocument.wordprocessingml.document`
    /// — the Office Open XML `.docx` Word format. The legacy binary
    /// `application/msword` (`.doc`) is deliberately NOT a constant here:
    /// it has no extraction path and stays classified `.binary`.
    public static let docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    /// `application/zip` — the generic archive container. Registered
    /// extractor inputs can BE zip containers (a `.docx` is one); the
    /// registry's registration surface, not the sniff, says which.
    public static let zip = "application/zip"

    /// `application/octet-stream` — the generic binary catch-all / fallback.
    public static let octetStream = "application/octet-stream"

    /// `text/markdown`.
    public static let markdown = "text/markdown"

    /// `text/x-markdown`.
    public static let markdownX = "text/x-markdown"

    /// `text/html`.
    public static let html = "text/html"

    /// `application/json` — JSON Canvas files use JSON as their registered
    /// media type. The `.canvas` extension remains the format discriminator.
    public static let json = "application/json"

    /// `application/xhtml+xml`.
    public static let xhtml = "application/xhtml+xml"

    /// `audio/podcast` — the synthetic source MIME for byteless RSS podcast
    /// feed sources. Not a real IANA media type: it exists so the URL-backed
    /// podcast-transcript extractor registration has a stable route MIME.
    public static let audioPodcast = "audio/podcast"

    /// `audio/apple-podcast` — the synthetic source MIME for byteless Apple
    /// Podcasts episode sources. Route MIME for the `apple-podcast-transcript`
    /// extractor registration; the input itself is the episode page URL.
    public static let audioApplePodcast = "audio/apple-podcast"

    /// `application/xml`.
    public static let xml = "application/xml"

    /// `image/svg+xml`.
    public static let svg = "image/svg+xml"

    /// `image/jpeg`.
    public static let imageJPEG = "image/jpeg"

    /// `video/youtube` — the synthetic embed type used by `ExternalEmbed`.
    public static let videoYouTube = "video/youtube"

    // MARK: - Sets / prefixes

    /// Prefix shared by every `text/*` type.
    public static let textPrefix = "text/"

    /// The recognized Markdown MIME variants (`text/markdown`, `text/x-markdown`).
    public static let markdownVariants: Set<String> = [markdown, markdownX]

    // MARK: - Predicates

    /// Whether `mime` is `application/pdf` (case-insensitive). `nil` is `false`.
    public static func isPDF(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.lowercased() == pdf
    }

    /// Whether `mime` is the Office Open XML Word `.docx` type
    /// (case-insensitive). `nil` is `false`. The legacy `application/msword`
    /// (`.doc`) does NOT match — it has no extraction path.
    public static func isDOCX(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.lowercased() == docx
    }

    /// Whether `mime` is any `text/*` type (case-insensitive prefix). `nil` is `false`.
    public static func isText(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime.lowercased().hasPrefix(textPrefix)
    }

    /// Whether source bytes can be presented as text without changing ingestion policy.
    /// XML is textual even when its MIME type is outside `text/*`; SVG remains visually
    /// renderable while also exposing its XML source.
    public static func isSourceTextPresentable(_ mime: String?) -> Bool {
        isText(mime) || isXML(mime)
    }

    /// Whether `mime` contains XML source that must display as code rather than markup.
    public static func isXML(_ mime: String?) -> Bool {
        guard let mime else { return false }
        let normalized = mime.lowercased()
        return normalized == "text/xml" || normalized == xml || normalized == svg
    }

    /// Whether `mime` is one of the recognized Markdown variants
    /// (`text/markdown` / `text/x-markdown`, case-insensitive). `nil` is `false`.
    public static func isMarkdown(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return markdownVariants.contains(mime.lowercased())
    }

    /// Extension-derived MIME for project-owned built-in and extractor formats.
    /// Renderer-owned formats are declared by active renderer packages instead.
    public static func mime(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "canvas": return json
        case "docx": return docx
        default: return nil
        }
    }
}
