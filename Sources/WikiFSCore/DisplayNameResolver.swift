import Foundation
import PDFKit

/// Resolves the best human-readable display name for a source at ingest time.
/// Returns `nil` when no richer metadata is available — the caller falls back to
/// the raw filename via `COALESCE(display_name, filename)`, preserving
/// backward-compatible link resolution for sources without extracted metadata.
///
/// Priority order:
/// 1. Zotero item title (when the source came from Zotero)
/// 2. Markdown front matter `title` (for `.md` / `text/markdown` files)
/// 3. PDF document title (from PDFKit metadata)
/// 4. `nil` — caller uses the filename
///
/// Pure and dependency-free (PDFKit is the only import), so the resolve function
/// is unit-testable with in-memory Data.
public enum DisplayNameResolver {

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

        // 2. Markdown front matter title.
        if isMarkdown(filename: filename, mimeType: mimeType),
           let title = extractMarkdownTitle(from: data) {
            return title
        }

        // 3. PDF document title.
        if isPDF(filename: filename, mimeType: mimeType),
           let title = extractPDFTitle(from: data) {
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

    // MARK: - PDF title

    /// Extract the document title from a PDF via PDFKit's document attributes.
    static func extractPDFTitle(from data: Data) -> String? {
        guard let document = PDFDocument(data: data),
              let attrs = document.documentAttributes,
              let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        else { return nil }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

// MARK: - String helper

private extension String {
    /// Returns `nil` when the string is empty after trimming whitespace.
    var nilIfEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
