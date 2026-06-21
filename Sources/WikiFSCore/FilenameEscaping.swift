import Foundation

/// Deterministic title → filename escaping for the `pages/by-title` projection
/// (INITIAL.md §5). Pure and dependency-free so it is unit-testable without the
/// File Provider runtime. The File Provider extension consumes these.
public enum FilenameEscaping {
    /// Escape a page title into the stem used under `pages/by-title`, applying
    /// the §5 rules in order:
    ///   1. collapse whitespace runs → a single space, then trim ends;
    ///   2. strip control characters (Unicode Cc) and NUL;
    ///   3. replace `/` and `:` with `-`;
    ///   4. if the result begins with `.`, prefix `_` (avoid hidden files);
    ///   5. trim trailing spaces and `.`;
    ///   6. if empty, use `untitled`.
    ///
    /// Examples: `Home` → `Home`; `File Provider / macOS?` → `File Provider - macOS?`.
    public static func escapeTitle(_ title: String) -> String {
        // (1) Collapse whitespace runs to a single space and trim.
        let collapsed = title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        // (2) Strip control characters (Cc) and NUL.
        var stripped = String(collapsed.unicodeScalars.filter { scalar in
            scalar != "\u{0}" && !controlCharacters.contains(scalar)
        })

        // (3) Replace path-hostile separators.
        stripped = stripped
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        // (4) Leading '.' → prefix '_'.
        if stripped.hasPrefix(".") {
            stripped = "_" + stripped
        }

        // (5) Trim trailing spaces and periods.
        while let last = stripped.last, last == " " || last == "." {
            stripped.removeLast()
        }

        // (6) Empty → untitled.
        return stripped.isEmpty ? "untitled" : stripped
    }

    /// The first 8 characters of a ULID, used as the disambiguating short-id
    /// suffix in human-readable filenames.
    public static func shortID(_ pageID: String) -> String {
        String(pageID.prefix(8))
    }

    /// The full `pages/by-title` filename: `<escaped-title>--<short-id>.md`.
    /// Example: `Home` + `01KV6EAH…` → `Home--01KV6EAH.md`.
    public static func byTitleFilename(title: String, pageID: String) -> String {
        "\(escapeTitle(title))--\(shortID(pageID)).md"
    }

    /// The canonical `pages/by-id` filename: `<full-ulid>.md`.
    public static func byIDFilename(pageID: String) -> String {
        "\(pageID).md"
    }

    // MARK: - Ingested files (Phase 5)

    /// The canonical `files/by-id` filename: `<full-ulid>.<ext>`, preserving the
    /// dropped file's original extension. The dot is omitted when `ext` is empty
    /// (extension-less drops): `01ABC…` → `01ABC…` (no trailing dot).
    public static func byIDSourceFilename(sourceID: String, ext: String) -> String {
        ext.isEmpty ? sourceID : "\(sourceID).\(ext)"
    }

    /// The human-readable `sources/by-name` filename:
    /// `<escaped-stem>--<short-id>.<ext>`. The original filename is split into
    /// its stem and extension; the STEM is escaped via `escapeTitle` (an
    /// empty/weird stem becomes `untitled`), the short id disambiguates
    /// collisions, and the ORIGINAL `ext` is preserved (dot omitted if empty).
    /// `Trip Report.PDF` + ext `pdf` → `Trip Report--01ABCDEF.pdf`.
    public static func byNameSourceFilename(filename: String, ext: String, sourceID: String) -> String {
        let ns = filename as NSString
        let stem = ns.deletingPathExtension
        let escapedStem = escapeTitle(stem)
        let base = "\(escapedStem)--\(shortID(sourceID))"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static let controlCharacters = CharacterSet.controlCharacters
}
