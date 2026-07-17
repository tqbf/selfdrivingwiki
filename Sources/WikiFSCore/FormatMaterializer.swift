import Foundation

/// The format-layer types and dispatcher, separated from origin (where bytes
/// came from). Given bytes + a content-type hint + a pre-computed filename stem
/// + an optional extension hint, `FormatMaterializer.dispatch` determines the
/// format, transforms if needed (HTML→Markdown), and derives the filename.
///
/// This is the extraction of the old `URLFetchService.plan(for:)` with the
/// `finalURL` replaced by a `stem: String` + `extensionHint: String?` pair, so
/// any byte-producing origin (website, local file, Zotero, …) can reuse format
/// dispatch without coupling to URL types.
///
/// See `plans/source-format-materializers.md`.

// MARK: - Source format

/// The format-layer subset of `FetchOutcome.Kind`: what a source produces after
/// dispatch (HTML→Markdown, PDF verbatim, text verbatim, binary verbatim).
/// Byteless origins (podcasts, embeds) bypass format dispatch entirely.
public enum SourceFormat: Sendable, Equatable {
    case htmlConverted   // HTML → Markdown
    case pdf             // verbatim PDF
    case text            // verbatim text
    case binary          // verbatim other bytes
}

/// A format dispatch result: the filename, bytes, and detected format — pure,
/// no URL/store/network dependency.
public struct FormatPlan: Sendable, Equatable {
    public let filename: String
    public let data: Data
    public let format: SourceFormat

    public init(filename: String, data: Data, format: SourceFormat) {
        self.filename = filename
        self.data = data
        self.format = format
    }
}

// MARK: - Dispatcher

/// A pure, URL-independent format dispatcher. Origin materializers acquire
/// bytes + build provenance, then delegate here for content-type dispatch,
/// HTML→Markdown conversion, and filename derivation.
public enum FormatMaterializer {

    /// Dispatch bytes to a `FormatPlan`: content-sniff ambiguous types, convert
    /// HTML→Markdown, store PDF/text/binary verbatim, and derive the filename
    /// from `stem` + `extensionHint`.
    ///
    /// - Parameters:
    ///   - data: The raw bytes.
    ///   - contentType: The declared content-type (may be `nil` — sniffed).
    ///   - stem: The pre-computed filename stem (extension already deleted by
    ///     the caller). For URL origins this is the last path component without
    ///     its extension, or the host for root URLs.
    ///   - extensionHint: The original file/URL extension (lowercased, without
    ///     the dot), or `nil` when there is none (root URLs, host fallback).
    ///     Used as the fallback extension for non-mapped text/binary MIMEs.
    public static func dispatch(
        data: Data,
        contentType: String?,
        stem: String,
        extensionHint: String?
    ) -> FormatPlan {
        let mime = normalizedMIME(contentType)

        // Content-sniff the bytes when the declared type is ambiguous
        // (`text/html`, missing, or `application/octet-stream`). If the bytes
        // carry a known binary magic number, store them verbatim as the sniffed
        // type instead of running HTML→Markdown on binary garbage. A specific
        // declared type is trusted as-is.
        if shouldSniff(mime), let sniffed = ContentSniff.mimeType(of: data) {
            let ext = binaryExtension(forMIME: sniffed, extensionHint: extensionHint)
            let filename = ext.isEmpty ? sanitizeStem(stem) : ensureExtension(sanitizeStem(stem), ext: ext)
            let format: SourceFormat = MimeType.isPDF(sniffed) ? .pdf : .binary
            return FormatPlan(filename: filename, data: data, format: format)
        }

        if mime == MimeType.html || mime == MimeType.xhtml {
            let html = decodeText(data)
            let result = HTMLToMarkdown.convert(html)
            let resolvedStem = result.title.flatMap { nonEmpty($0) } ?? stem
            let filename = ensureExtension(sanitizeStem(resolvedStem), ext: "md")
            return FormatPlan(filename: filename, data: Data(result.markdown.utf8), format: .htmlConverted)
        }

        if MimeType.isPDF(mime) {
            let filename = ensureExtension(sanitizeStem(stem), ext: "pdf")
            return FormatPlan(filename: filename, data: data, format: .pdf)
        }

        if let mime, MimeType.isText(mime) {
            let ext = textExtension(forMIME: mime, extensionHint: extensionHint)
            let filename = ensureExtension(sanitizeStem(stem), ext: ext)
            return FormatPlan(filename: filename, data: data, format: .text)
        }

        // Anything else: keep bytes verbatim with a best-effort extension.
        let ext = binaryExtension(forMIME: mime, extensionHint: extensionHint)
        let filename = ext.isEmpty ? sanitizeStem(stem) : ensureExtension(sanitizeStem(stem), ext: ext)
        return FormatPlan(filename: filename, data: data, format: .binary)
    }

    // MARK: - Content sniffing (pure)

    /// Whether a declared MIME is ambiguous enough to second-guess via the bytes:
    /// `text/html` (the interstitial case), a missing type, or the catch-all
    /// `application/octet-stream`. A specific declared type is trusted as-is.
    static func shouldSniff(_ mime: String?) -> Bool {
        switch mime {
        case nil, MimeType.html, MimeType.xhtml, MimeType.octetStream:
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers (pure)

    /// Lowercased MIME with any `; charset=…` parameter and whitespace stripped.
    static func normalizedMIME(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = raw.split(separator: ";", maxSplits: 1).first.map(String.init) ?? raw
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decode bytes as text — UTF-8 first, then Latin-1 (which never fails) so
    /// a mis-declared charset still produces *something* the HTML walker can use.
    static func decodeText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(decoding: data, as: UTF8.self)  // lossy, never nil
    }

    /// Sanitize a stem into a safe filename component. Reuses `FilenameEscaping`'s
    /// title rules, then caps the length so a giant `<title>` can't make an
    /// unwieldy filename.
    static func sanitizeStem(_ stem: String) -> String {
        let escaped = FilenameEscaping.escapeTitle(stem)
        let capped = String(escaped.prefix(80)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? "untitled" : capped
    }

    /// Append `.ext` unless the stem already ends in it (case-insensitive).
    static func ensureExtension(_ stem: String, ext: String) -> String {
        let lower = stem.lowercased()
        if lower.hasSuffix(".\(ext)") { return stem }
        return "\(stem).\(ext)"
    }

    /// Extension for a `text/*` response: map the common ones, else fall back to
    /// `extensionHint`, else `txt`.
    static func textExtension(forMIME mime: String, extensionHint: String?) -> String {
        switch mime {
        case MimeType.markdown, MimeType.markdownX: return "md"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "text/css": return "css"
        case "text/javascript": return "js"
        default:
            if let ext = extensionHint, !ext.isEmpty { return ext }
            return "txt"
        }
    }

    /// Extension for a non-text response: from the MIME subtype when recognizable,
    /// else `extensionHint`, else empty (no extension).
    static func binaryExtension(forMIME mime: String?, extensionHint: String?) -> String {
        if let mime {
            switch mime {
            case MimeType.imageJPEG: return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            case "application/json": return "json"
            case "application/zip": return "zip"
            case "application/epub+zip": return "epub"
            default:
                // Use the subtype if it looks like a clean extension token.
                if let sub = mime.split(separator: "/").last,
                   sub.allSatisfy({ $0.isLetter || $0.isNumber }), !sub.isEmpty {
                    return String(sub)
                }
            }
        }
        return extensionHint ?? ""
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
