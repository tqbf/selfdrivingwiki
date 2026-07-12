import Foundation

/// Shared logic for the page-markdown contract: the editor stores only the
/// body (no H1, no frontmatter); the file-provider generates both on the fly.
public enum PageMarkdownFormat {

    /// Strip leading YAML frontmatter, a matching H1, and the blank lines that
    /// follow them from a stored page body. Called on load so the editor never
    /// sees generated decoration, and on rename so SQLite stays clean.
    public static func stripped(body: String, title: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var i = 0

        // Strip YAML frontmatter block (opening --- … closing ---)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            i = 1
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                i += 1
            }
            if i < lines.count { i += 1 } // consume closing ---
        }

        // Skip blank lines between frontmatter and body
        while i < lines.count && lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            i += 1
        }

        // Strip leading H1 when it matches the page title exactly
        if i < lines.count && lines[i] == "# \(title)" {
            i += 1
        }

        // Skip blank lines that followed the H1
        while i < lines.count && lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            i += 1
        }

        guard i > 0 else { return body }
        return lines[i...].joined(separator: "\n")
    }

    /// Generate the complete on-disk content served by the file provider:
    /// YAML frontmatter + blank line + H1 + blank line + body.
    /// `body_markdown` in SQLite must already be clean (no frontmatter, no H1)
    /// before calling this; pass through `stripped(body:title:)` if unsure.
    ///
    /// Provenance fields (created_by, last_edited_by) are included when present
    /// (#131). When absent (pre-#131 rows), they are omitted — the agent and
    /// readers can treat them as "unknown".
    public static func fileContent(for page: WikiPage) -> String {
        let dateStr = localDateString(from: page.updatedAt)
        let escapedTitle = page.title.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
        let cleanBody = stripped(body: page.bodyMarkdown, title: page.title)

        // Build frontmatter, conditionally adding provenance fields.
        var fm = "title: \"\(escapedTitle)\"\ndate: \(dateStr)"
        if let createdBy = page.createdBy {
            fm += "\ncreated_by: \(createdBy)"
        }
        if let lastEditedBy = page.lastEditedBy, lastEditedBy != page.createdBy {
            fm += "\nlast_edited_by: \(lastEditedBy)"
        }

        var result = "---\n\(fm)\n---\n\n# \(page.title)"
        if !cleanBody.isEmpty {
            result += "\n\n\(cleanBody)"
        }
        return result
    }

    // MARK: - Private

    static func localDateString(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Shared logic for the source-markdown frontmatter contract: the processed
/// markdown body is stored without frontmatter; the file provider adds it on
/// the fly when serving the `.md` sibling so readers can see provenance
/// (origin, processing date, extraction technique) without a side channel.
public enum SourceMarkdownFormat {

    /// Wrap a source markdown version's body with YAML frontmatter carrying
    /// provenance metadata (#131). Frontmatter is omitted for empty bodies.
    public static func fileContent(for version: SourceMarkdownVersion) -> String {
        var fm: [String] = []
        fm.append("origin: \(version.origin)")
        fm.append("date: \(PageMarkdownFormat.localDateString(from: version.createdAt))")
        if let technique = version.technique {
            fm.append("technique: \(technique)")
        }
        if let note = version.note, !note.isEmpty {
            let escaped = note.replacingOccurrences(of: "\"", with: "\\\"")
            fm.append("note: \"\(escaped)\"")
        }
        return "---\n\(fm.joined(separator: "\n"))\n---\n\n\(version.content)"
    }
}
