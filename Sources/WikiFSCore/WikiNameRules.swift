import Foundation

/// Sanitization rules for page titles and source display names.
///
/// The `[[wiki-link]]` grammar reserves characters it cannot escape: `]` ends
/// the span, `|` starts the alias, and a leading `#` reads as a same-page
/// anchor. A name containing one of those can NEVER be linked — they break
/// the bracket regex before any resolution runs — so storing such a name just
/// plants a silent dead end. A `#` anywhere ELSE in a name is fine:
/// `WikiLinkResolver` disambiguates it against the real namespace.
///
/// Names are sanitized (not rejected) at every write boundary — `createPage`,
/// `updatePage`, `renameSource`, `addSource`, `PageUpsert` — and once for
/// pre-existing rows by the v17→18 store migration, so the invariant holds:
/// **every stored name is linkable**.
///
/// `[` alone doesn't break the grammar, but it is mapped alongside `]` so
/// bracketed names stay paired — "[Editorial] X" becomes "(Editorial) X",
/// not the mismatched "[Editorial) X".
public enum WikiNameRules {

    /// `name` with unlinkable characters replaced (`|` → `-`, `[`/`]` →
    /// `(`/`)`), leading `#`s dropped, and ends trimmed. Idempotent. Returns
    /// "Untitled" when nothing displayable is left.
    public static func sanitized(_ name: String) -> String {
        var s = name
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.first == "#" {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? "Untitled" : s
    }

    /// True when `name` is already linkable as-is (sanitizing wouldn't change
    /// it). Used by the migration to find rows that need the one-time fix.
    public static func isLinkable(_ name: String) -> Bool {
        sanitized(name) == name
    }

    /// A LENIENT comparison key for source-name matching: normalized,
    /// lowercased, with one trailing file extension and one trailing
    /// parenthesized suffix stripped — so an agent-written citation like
    /// `[[source:Some Paper (2026)]]` can still find a source named
    /// "Some Paper.pdf". Both sides of a comparison get the same treatment,
    /// and callers only act on a UNIQUE match across all sources
    /// (`resolveSourceByName` pass 3, the reader's ghost-styling sets), so a
    /// near-miss never silently picks between two plausible sources.
    public static func looseMatchKey(_ name: String) -> String {
        var s = WikiText.normalized(name).lowercased()
        // One trailing ".ext" — only if it looks like a real file extension
        // (1–5 alphanumerics), so "v2.5" style names lose at most a digit and
        // both sides lose it identically.
        let ext = (s as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            s = (s as NSString).deletingPathExtension as String
        }
        // One trailing "(…)" suffix: "some paper (2026)" → "some paper".
        if let range = s.range(of: #"\s*\([^()]*\)\s*$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return WikiText.normalized(s)
    }
}
