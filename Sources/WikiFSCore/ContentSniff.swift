import Foundation

/// Pure, dependency-free content-type detection from magic bytes (the leading
/// bytes of a data blob). Extracted from `URLFetchService` so the store,
/// ingest paths, and any future caller can sniff without depending on the
/// URL-fetch layer.
///
/// Kept deliberately small: each magic-number check copies at most 8 bytes.
/// Extend the table as needed (Office docs, EPUB, etc.).
public enum ContentSniff {

    /// Content-derived MIME type from leading magic-number bytes, or `nil` if
    /// the bytes don't match any known binary signature. Cheap prefix check
    /// only — this is NOT a full content inspector.
    public static func mimeType(of data: Data) -> String? {
        let head = Array(data.prefix(8))
        func starts(with magic: [UInt8]) -> Bool {
            guard head.count >= magic.count else { return false }
            return Array(head.prefix(magic.count)) == magic
        }

        if starts(with: Array("%PDF".utf8)) { return "application/pdf" }
        if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }  // \x89PNG
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }  // PK\x03\x04
        return nil
    }
}

/// Canonical MIME-type constants and typed predicates.
///
/// Centralizes the literals that were previously compared inline across the
/// codebase (`"application/pdf"`, `hasPrefix("text/")`, the `application/octet-stream`
/// fallback, the Markdown variants, etc.). Routing every comparison, prefix
/// check, and switch label through here keeps the canonical strings in one
/// place — a typo like `"application/pdf "` can no longer silently mis-guard,
/// because a single typo'd call site just becomes a compile-time mismatch.
///
/// All matching is **case-insensitive**, per RFC 2045 (MIME types are
/// case-insensitive). Stored types are normally lowercase already
/// (`ContentSniff` and `FormatMaterializer.normalizedMIME` both lowercase),
/// but accepting any casing here makes the predicates correct regardless of
/// how a type reached the codebase (e.g. a raw `Content-Type` header).
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
}
