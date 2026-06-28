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
    public static func fileContent(for page: WikiPage) -> String {
        let dateStr = localDateString(from: page.updatedAt)
        let escapedTitle = page.title.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
        let cleanBody = stripped(body: page.bodyMarkdown, title: page.title)

        var result = "---\ntitle: \"\(escapedTitle)\"\ndate: \(dateStr)\n---\n\n# \(page.title)"
        if !cleanBody.isEmpty {
            result += "\n\n\(cleanBody)"
        }
        return result
    }

    // MARK: - Private

    private static func localDateString(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
