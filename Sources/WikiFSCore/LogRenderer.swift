import Foundation

/// Pure, deterministic rendering of the `log` table into the grep-able `log.md`
/// body (Phase B). Split out (like `IndexGenerators`) so the projection reads
/// SQLite and the formatting is unit-tested in isolation.
///
/// Each entry becomes a heading line whose prefix the doc's
/// `grep "^## \[" log.md | tail -5` recipe matches exactly:
///
///     ## [2026-06-15] ingest | Article Title
///     ## [2026-06-15] query | "How does X compare to Y?"
///
/// followed, if the entry carries a note, by the note on the next line. Entries
/// are rendered in chronological order (oldest-first; ULID id == creation order),
/// so newly-appended rows land at the bottom and `tail` shows the most recent.
public enum LogRenderer {

    /// The `[YYYY-MM-DD]` date stamp uses a fixed, locale-independent formatter so
    /// the rendered lines are stable regardless of the host locale/timezone
    /// settings (UTC), matching the doc's literal format.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Render the whole log as the `log.md` body. An empty log renders an empty
    /// document, so the file always exists.
    public static func render(_ entries: [LogEntry]) -> String {
        entries.map(line(for:)).joined(separator: "\n")
    }

    /// One entry's markdown: the grep-able `## [date] kind | title` heading, plus
    /// the note on a following line when present.
    private static func line(for entry: LogEntry) -> String {
        let date = dateFormatter.string(from: entry.timestamp)
        let heading = "## [\(date)] \(entry.kind.rawValue) | \(entry.title)"
        guard let note = entry.note, !note.isEmpty else { return heading + "\n" }
        return heading + "\n" + note + "\n"
    }
}
