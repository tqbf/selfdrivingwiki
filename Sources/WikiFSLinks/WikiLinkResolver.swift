import Foundation

/// Lookup-driven disambiguation for `[[wiki-link]]` targets whose NAME may
/// contain `#`.
///
/// The link grammar has no escape syntax, so a raw target like
/// `C# Guide#Methods` is ambiguous on its face: the name could be
/// "C# Guide#Methods", "C# Guide" (with a "Methods" anchor), or "C" (with a
/// "# Guide#Methods" anchor). Guessing from the characters alone can't settle
/// it — but the consumers that resolve links all KNOW the namespace (the
/// reader's existence sets, the store's resolve queries). So: try every
/// possible split, longest name first, and take the first whose name exists.
/// An exact full-target match beats any anchor reading — the only precedence
/// that stays correct for names containing `#`, `#"`, or both.
///
/// Pure and dependency-free (the namespace arrives as a closure) so it is
/// trivially unit-testable and shared by the store (`replaceLinks`), the
/// renderer (`WikiLinkMarkdown.linkified`), and the editor lint
/// (`WikiStoreModel.preflightLint`). Unresolvable targets fall back to the
/// caller's heuristic split (`WikiLinkParser.splitFragment`) — there is no
/// namespace to consult for a ghost link.
public enum WikiLinkResolver {

    /// One possible reading of a raw target: a normalized base name plus the
    /// verbatim remainder after the splitting `#` (`nil` = no fragment).
    public struct Split: Equatable, Sendable {
        public let base: String
        public let fragment: String?

        public init(base: String, fragment: String?) {
            self.base = base
            self.fragment = fragment
        }
    }

    /// All plausible `(base, fragment)` readings of `rawTarget` (whitespace-
    /// collapsed, prefix-stripped), longest base first: the whole string with
    /// no fragment, then a split at each `#` from rightmost to leftmost.
    /// Bases are normalized; a split with an empty base is skipped (that
    /// reading is a same-page anchor, not a name).
    public static func candidateSplits(of rawTarget: String) -> [Split] {
        var out = [Split(base: WikiText.normalized(rawTarget), fragment: nil)]
        for index in rawTarget.indices.reversed() where rawTarget[index] == "#" {
            let base = WikiText.normalized(String(rawTarget[..<index]))
            guard !base.isEmpty else { continue }
            let fragment = String(rawTarget[rawTarget.index(after: index)...])
            out.append(Split(base: base, fragment: fragment.isEmpty ? nil : fragment))
        }
        return out
    }

    /// The first candidate reading whose base names something real per
    /// `isKnown`, or `nil` when none does (a ghost link).
    public static func resolvedSplit(
        of rawTarget: String,
        isKnown: (String) throws -> Bool
    ) rethrows -> Split? {
        for split in candidateSplits(of: rawTarget) {
            if try isKnown(split.base) { return split }
        }
        return nil
    }
}
