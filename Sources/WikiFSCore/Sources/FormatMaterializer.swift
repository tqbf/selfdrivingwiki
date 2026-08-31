import Foundation

// pattern: Functional Core

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
/// dispatch (HTML verbatim, PDF verbatim, text verbatim, binary verbatim).
/// Byteless origins (podcasts, embeds) bypass format dispatch entirely.
///
/// Issue #599: HTML sources are treated like PDF sources — the original HTML
/// bytes are the source blob (`.html` format), and any extracted markdown rides
/// as a `FormatPlan.extractedMarkdown` sidecar that the store path writes as a
/// `SourceMarkdownOrigin.extraction` processed-markdown version. This replaces
/// the old `.htmlConverted` behavior that stored ONLY the markdown and
/// discarded the original HTML.
///
/// Issue #799 PR3: `dispatch` no longer populates `extractedMarkdown` for
/// non-snapshot HTML at ingest time — the user triggers extraction via the
/// Extract button (PR2). The snapshot-with-images path (via
/// `WebsiteSnapshotExtractor`) STILL sets the sidecar because image-src
/// rewriting is inseparable from extraction there.
public enum SourceFormat: Sendable, Equatable {
    case html           // verbatim HTML (sidecar only on snapshot path post-PR3)
    case pdf            // verbatim PDF
    case docx           // verbatim Word document (extractable via docx2md)
    case text            // verbatim text
    case binary          // verbatim other bytes
}

/// A format dispatch result: the filename, bytes, and detected format — pure,
/// no URL/store/network dependency.
///
/// For HTML sources (`.html` format), `extractedMarkdown` carries the
/// HTML→Markdown conversion (mirrors PDF → pdf2md extraction: original bytes
/// live as the source blob, extracted markdown as a processed-markdown version).
/// `nil` for non-HTML formats, AND `nil` for non-snapshot HTML at the
/// `dispatch` seam post-PR3 (issue #799 — non-snapshot HTML no longer
/// auto-extracts at ingest; the snapshot path overrides the field downstream
/// via `WebsiteSnapshotExtractor`).
public struct FormatPlan: Sendable, Equatable {
    public let filename: String
    public let data: Data
    public let format: SourceFormat
    public let detectionResult: ContentTypeDetectionResult
    public let extractedMarkdown: String?

    public init(
        filename: String,
        data: Data,
        format: SourceFormat,
        detectionResult: ContentTypeDetectionResult? = nil,
        extractedMarkdown: String? = nil
    ) {
        self.filename = filename
        self.data = data
        self.format = format
        self.detectionResult = detectionResult ?? ContentTypeDetector.detect(.init(
            data: data,
            hints: .init(filename: filename)))
        self.extractedMarkdown = extractedMarkdown
    }
}

// MARK: - HTML extraction protocol

// `HtmlMarkdownExtractor` protocol + `HtmlExtractionResult` value type moved to
// `Sources/WikiFSMarkdown/HtmlMarkdownExtractor.swift` (issue #799 PR2) so the
// always-available `TagBasedHtmlExtractor` conformer in `HTMLToMarkdown.swift`
// can see the protocol without a circular module dependency. `WikiFSCore`
// re-exports `WikiFSMarkdown` (`@_exported import` in `ModuleExports.swift`),
// so all existing callers in this module + downstream continue to see the
// types unchanged.

// MARK: - Dispatcher

/// A pure, URL-independent format dispatcher. Origin materializers acquire
/// bytes + build provenance, then delegate here for content-type dispatch,
/// HTML→Markdown conversion, and filename derivation.
public enum FormatMaterializer {

    /// Return a JSON document extension that should survive generic server
    /// MIME types. GitHub's raw endpoint reports `.canvas` as `text/plain`,
    /// while the local source MIME table identifies it as JSON Canvas.
    private static func jsonDocumentExtension(from extensionHint: String?) -> String? {
        guard let extensionHint,
              MimeType.mime(forExtension: extensionHint) == MimeType.json
        else { return nil }
        return extensionHint.lowercased()
    }

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
        hints: ContentTypeDetectionHints,
        stem: String,
        extensionHint: String?,
        registeredInputs: RegisteredExtractionInputs = .none
    ) -> FormatPlan {
        let detection = ContentTypeDetector.detect(.init(data: data, hints: hints))
        return dispatch(
            data: data,
            detectionResult: detection,
            stem: stem,
            extensionHint: extensionHint,
            registeredInputs: registeredInputs)
    }

    public static func dispatch(
        data: Data,
        contentType: String?,
        stem: String,
        extensionHint: String?
    ) -> FormatPlan {
        dispatch(
            data: data,
            hints: .init(
                declaredMIME: contentType.map { .init($0, origin: .httpResponse) },
                filenameExtension: extensionHint),
            stem: stem,
            extensionHint: extensionHint)
    }

    public static func dispatch(
        data: Data,
        detectionResult: ContentTypeDetectionResult,
        stem: String,
        extensionHint: String?,
        registeredInputs: RegisteredExtractionInputs = .none
    ) -> FormatPlan {
        var mime = detectionResult.normalizedMIMEType

        // Registration-driven recognition: a registered input that IS an
        // archive container (a `.docx` is a ZIP the sniffer resolves to
        // application/zip) promotes to the registered MIME when an active
        // registration declares this file's extension or MIME. The
        // registration, not the sniff, says the container has an extraction
        // path.
        if let promoted = registeredInputs.promotedMIME(
            detectedMIME: mime,
            declaredMIME: nil,
            filenameExtension: extensionHint) {
            mime = promoted
        }

        if mime == MimeType.html || mime == MimeType.xhtml {
            let html = decodeText(data)
            let resolvedStem = HTMLToMarkdown.titleOnly(from: html)
                .flatMap { nonEmpty($0) } ?? stem
            let filename = ensureExtension(sanitizeStem(resolvedStem), ext: "html")
            return FormatPlan(
                filename: filename,
                data: data,
                format: .html,
                detectionResult: detectionResult,
                extractedMarkdown: nil)
        }

        if MimeType.isPDF(mime) {
            let filename = ensureExtension(sanitizeStem(stem), ext: "pdf")
            return FormatPlan(
                filename: filename, data: data, format: .pdf,
                detectionResult: detectionResult)
        }

        // OOXML Word documents keep their bytes verbatim as the source blob.
        // The registry-driven store path starts extraction after import. This
        // dispatcher only preserves the DOCX format and filename.
        // Legacy `application/msword` (.doc) stays `.binary` — no path.
        if MimeType.isDOCX(mime) {
            let filename = ensureExtension(sanitizeStem(stem), ext: "docx")
            return FormatPlan(
                filename: filename, data: data, format: .docx,
                detectionResult: detectionResult)
        }

        if let mime, MimeType.isText(mime) {
            let ext = textExtension(forMIME: mime, extensionHint: extensionHint)
            let filename = ensureExtension(sanitizeStem(stem), ext: ext)
            return FormatPlan(
                filename: filename, data: data, format: .text,
                detectionResult: detectionResult)
        }

        let ext = binaryExtension(forMIME: mime, extensionHint: extensionHint)
        let filename = ext.isEmpty ? sanitizeStem(stem) : ensureExtension(sanitizeStem(stem), ext: ext)
        return FormatPlan(
            filename: filename, data: data, format: .binary,
            detectionResult: detectionResult)
    }

    // MARK: - HTML enrichment (async, injectable)

    /// Best-effort: if the plan is HTML, run the defuddle extractor to obtain
    /// site-specific markdown + metadata; on any failure, keep the tag-based
    /// markdown already on the plan. Returns the (possibly rewritten) plan and
    /// the technique tag to stamp on the stored version.
    ///
    /// `dispatch` stays pure + synchronous (it's called from tests and the
    /// pure-dispatch contract is valuable). This async helper is called by
    /// materializers after `dispatch`.
    public static func enrich(
        _ plan: FormatPlan,
        using extractor: (any HtmlMarkdownExtractor)?
    ) async -> (plan: FormatPlan, technique: String) {
        guard plan.format == .html, let extractor else {
            return (plan, "html-to-markdown")
        }
        let html = decodeText(plan.data)
        guard let result = await extractor.extract(html: html) else {
            // Fallback: keep tag-based extractedMarkdown already on the plan.
            return (plan, "html-to-markdown")
        }
        // Defuddle's <title> may be richer than the tag-based heuristic. Use it
        // for the filename when available (mirrors dispatch's title→stem logic).
        let stem: String
        if let title = result.title.flatMap({ nonEmpty($0) }) {
            stem = sanitizeStem(title)
        } else {
            stem = sanitizeStem((plan.filename as NSString).deletingPathExtension)
        }
        let filename = ensureExtension(stem, ext: "html")
        return (
            FormatPlan(
                filename: filename,
                data: plan.data,
                format: .html,
                detectionResult: plan.detectionResult,
                extractedMarkdown: result.markdown
            ),
            "defuddle"
        )
    }

    // MARK: - Helpers (pure)

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
    /// `extensionHint`, else `txt`. A plain-text file keeps its own extension
    /// when it has one: the sniff says only "this is text", and the extension is
    /// the user's format declaration — an `architecture.d2` must not be silently
    /// rewritten to `architecture.txt`.
    static func textExtension(forMIME mime: String, extensionHint: String?) -> String {
        if let jsonExtension = jsonDocumentExtension(from: extensionHint) {
            return jsonExtension
        }
        switch mime {
        case MimeType.markdown, MimeType.markdownX: return "md"
        case "text/csv": return "csv"
        case "text/css": return "css"
        case "text/javascript": return "js"
        case "text/plain":
            if let hint = extensionHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !hint.isEmpty, hint.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                return hint
            }
            return "txt"
        default:
            if let ext = extensionHint, !ext.isEmpty { return ext }
            return "txt"
        }
    }

    /// Extension for a non-text response: the known MIME table first, then
    /// the file's own extension when it is a clean token, then the MIME
    /// subtype as a guess for hint-less bytes, else empty.
    static func binaryExtension(forMIME mime: String?, extensionHint: String?) -> String {
        if let jsonExtension = jsonDocumentExtension(from: extensionHint) {
            return jsonExtension
        }
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
            case MimeType.docx: return "docx"
            default:
                // The file's own extension wins over a guessed subtype: a
                // dropped `notes.doc` with `application/msword` keeps `.doc`
                // — the subtype ("msword") would rename the user's file. The
                // subtype stays the fallback for hint-less bytes.
                if let kept = Self.cleanExtensionToken(extensionHint) {
                    return kept
                }
                if let sub = mime.split(separator: "/").last,
                   sub.allSatisfy({ $0.isLetter || $0.isNumber }), !sub.isEmpty {
                    return String(sub)
                }
            }
        }
        return extensionHint ?? ""
    }

    /// The last dot-component of `hint` when it is a clean alphanumerical
    /// token, else nil.
    static func cleanExtensionToken(_ hint: String?) -> String? {
        guard let hint,
              let token = hint.split(separator: ".").last,
              !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return String(token)
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
