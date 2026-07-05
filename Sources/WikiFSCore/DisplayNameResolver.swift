import Foundation

/// Resolves the best human-readable display name for a source at ingest time.
/// Returns `nil` when no richer metadata is available — the caller falls back to
/// the raw filename via `COALESCE(display_name, filename)`, preserving
/// backward-compatible link resolution for sources without extracted metadata.
///
/// Priority order:
/// 1. Zotero item title (when the source came from Zotero)
/// 2. Markdown front matter `title` (for `.md` / `text/markdown` files)
/// 3. Markdown leading `# ` ATX heading (when front matter is absent or has no `title`)
/// 4. PDF document title (via PDFKit metadata)
/// 5. `nil` — caller uses the filename
///
/// The Zotero + markdown paths are pure Foundation. The PDF-title step needs
/// PDFKit, which transitively links **AppKit** — forbidden in the read-only
/// File Provider extension (`WikiFSFileProvider`) that also links `WikiFSCore`
/// on macOS 26 (`com.apple.fileprovider-nonui`). So PDF extraction is
/// **injectable**: ``pdfTitleExtractor`` defaults to a `nil`-returning closure
/// (used by the extension, `wikictl`, and tests by default) and the app installs
/// the real PDFKit implementation at launch. This keeps `WikiFSCore` — and
/// therefore the extension — free of PDFKit/AppKit at link time.
public enum DisplayNameResolver {

    /// PDF document-title extractor. Defaults to "no metadata" (`{ _ in nil }`)
    /// so this type stays free of PDFKit/AppKit. The app installs the real PDFKit
    /// implementation at launch (`WikiFS.PDFTitleExtractor.extract`); every
    /// non-app context (extension, CLI, tests) leaves the default and simply
    /// falls through to the filename.
    public nonisolated(unsafe) static var pdfTitleExtractor: (Data) -> String? = { _ in nil }

    /// Resolve a display name from the available metadata and file bytes.
    /// - Parameters:
    ///   - filename: The original filename (e.g. `"Trip Report.pdf"`).
    ///   - data: The verbatim file bytes (used for front matter / PDF metadata).
    ///   - mimeType: Best-effort MIME type (used to skip expensive checks on
    ///     obviously-wrong types).
    ///   - zoteroItemTitle: The Zotero parent item title when this source came
    ///     from the Zotero ingest seam; `nil` otherwise.
    /// - Returns: A display name string, or `nil` when no richer metadata is
    ///   available (caller falls back to the filename).
    public static func resolve(
        filename: String,
        data: Data,
        mimeType: String?,
        zoteroItemTitle: String?
    ) -> String? {
        // 1. Zotero title — the richest metadata we have.
        if let zoteroTitle = zoteroItemTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !zoteroTitle.isEmpty {
            return zoteroTitle
        }

        // 2. Markdown front matter title, falling back to a leading H1 heading
        //    when front matter is absent or has no `title:` key.
        if isMarkdown(filename: filename, mimeType: mimeType) {
            if let title = extractMarkdownTitle(from: data) {
                return title
            }
            if let heading = extractMarkdownHeading(from: data) {
                return heading
            }
        }

        // 3. PDF document title (via the injectable extractor — nil-returning
        //    unless the app installed the PDFKit implementation).
        if isPDF(filename: filename, mimeType: mimeType),
           let title = pdfTitleExtractor(data) {
            return title
        }

        // 4. No richer metadata — caller uses the raw filename.
        return nil
    }

    // MARK: - Type detection

    private static func isMarkdown(filename: String, mimeType: String?) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return true }
        if let mime = mimeType?.lowercased(),
           mime == "text/markdown" || mime == "text/x-markdown" {
            return true
        }
        return false
    }

    private static func isPDF(filename: String, mimeType: String?) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "pdf" { return true }
        if let mime = mimeType?.lowercased(), mime == "application/pdf" {
            return true
        }
        return false
    }

    // MARK: - Markdown front matter

    /// Extract `title` from YAML front matter (`---\n...\n---` at the start of
    /// the file). Recognises both `title: "value"` and `title: value` forms;
    /// handles trailing whitespace and quotes.
    static func extractMarkdownTitle(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let scanner = Scanner(string: text)
        _ = scanner.charactersToBeSkipped = nil  // don't auto-skip whitespace

        // Skip any leading whitespace or newlines before the opening `---`.
        _ = scanner.scanCharacters(from: .whitespacesAndNewlines)

        // Front matter must start with `---` as the first non-blank line.
        guard scanner.scanString("---") != nil else { return nil }

        // Scan past the newline after the opening `---`.
        _ = scanner.scanCharacters(from: .newlines)

        // Scan lines until the closing `---`.
        while !scanner.isAtEnd {
            // Check if we've hit the closing `---`.
            if scanner.scanString("---") != nil {
                break  // closing delimiter found — stop scanning
            }

            // Read one line.
            guard let line = scanner.scanUpToCharacters(from: .newlines) else { break }
            _ = scanner.scanCharacters(from: .newlines)

            // Try to match `title: "value"` or `title: value`.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("title:") else { continue }

            let valuePart = String(trimmed.dropFirst("title:".count))
                .trimmingCharacters(in: .whitespaces)

            // Handle quoted values: `"My Title"` or `'My Title'`.
            if valuePart.hasPrefix("\"") {
                let inner = valuePart.dropFirst()
                // Find closing quote, handling escaped quotes.
                var result = ""
                var escaped = false
                for ch in inner {
                    if escaped {
                        result.append(ch)
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        return result.trimmingCharacters(in: .whitespaces).nilIfEmpty
                    } else {
                        result.append(ch)
                    }
                }
                // No closing quote found — return the inner text as-is.
                let fallback = result.trimmingCharacters(in: .whitespaces)
                return fallback.nilIfEmpty
            }

            if valuePart.hasPrefix("'") {
                let inner = valuePart.dropFirst()
                if let closeQuote = inner.firstIndex(of: "'") {
                    let result = String(inner[..<closeQuote])
                        .trimmingCharacters(in: .whitespaces)
                    return result.nilIfEmpty
                }
            }

            // Unquoted value — take everything until end of line (already trimmed).
            return valuePart.nilIfEmpty
        }

        return nil
    }

    // MARK: - Markdown leading heading

    /// Extract the text of a leading `# ` ATX heading — the first non-blank
    /// line of content (after skipping past any front-matter block, whether
    /// or not it had a `title:` key). Deeper headings (`##` and beyond) do
    /// not count; the heading must be the first line of content.
    static func extractMarkdownHeading(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = ArraySlice(text.components(separatedBy: .newlines))

        // Skip leading blank lines.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = lines.dropFirst()
        }

        // Skip a front-matter block, if present, regardless of whether it
        // contained a `title:` key.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != "---" {
                lines = lines.dropFirst()
            }
            if !lines.isEmpty { lines = lines.dropFirst() }  // drop closing `---`

            // Skip blank lines between the closing `---` and the heading.
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines = lines.dropFirst()
            }
        }

        guard let headingLine = lines.first else { return nil }
        let trimmed = headingLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# "), !trimmed.hasPrefix("##") else { return nil }
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    // MARK: - PDF title

    // PDF title extraction is injected via ``pdfTitleExtractor`` so that this
    // target does not import PDFKit (which pulls AppKit into the File Provider
    // extension). The PDFKit implementation lives in the app target
    // (`WikiFS.PDFTitleExtractor`) and is installed at launch.
}

// MARK: - String helper

private extension String {
    /// Returns `nil` when the string is empty after trimming whitespace.
    var nilIfEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
