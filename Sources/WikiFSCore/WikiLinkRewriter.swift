import Foundation

/// Pure, dependency-free helper that rewrites `[[source:<oldBase>…]]` spans when
/// a source's display name changes (Phase D). Reuses `WikiLinkSpan` for the regex
/// and code-range detection, and `WikiLinkParser` for classification.
public enum WikiLinkRewriter {

    /// In `body`, find every `[[source:<oldBase>…]]` link span (skipping code
    /// spans/fences), and swap `<oldBase>` for `<newBase>`, leaving any
    /// `#fragment` and `|alias` verbatim. Returns `nil` if no span matched (so
    /// callers can skip the re-save). Case-insensitive, whitespace-collapsed
    /// base match (same normalization as `WikiLinkParser.classify`).
    ///
    /// The match is by DIRECT string comparison, not by delimiter guessing: the
    /// old name is known, so after the `source:` prefix every candidate slice —
    /// the whole remainder first, then up to each `#` from rightmost to
    /// leftmost — is compared (normalized, case-insensitive) against `oldBase`,
    /// and the first hit is spliced. That way a name CONTAINING `#` (e.g.
    /// "…for C# Security Auditing"), cited with or without a `#"quote"` anchor,
    /// matches whole instead of being truncated at its first `#`.
    ///
    /// `isNameKnown` mirrors `WikiLinkResolver`'s longest-name-wins rule: when
    /// a LONGER candidate slice names some OTHER existing source (e.g. old name
    /// "C", but the span reads `[[source:C# Notes]]` and a source "C# Notes"
    /// exists), that longer name owns the link and the span is left alone.
    /// Callers with no namespace can omit it (nothing else is "known").
    public static func rewriteSourceBase(
        in body: String,
        matching oldBase: String,
        to newBase: String,
        isNameKnown: (String) -> Bool = { _ in false }
    ) -> String? {
        let ns = body as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)
        let matches = WikiLinkSpan.regex.matches(
            in: body, range: NSRange(location: 0, length: ns.length))

        let normalizedOld = WikiText.normalized(oldBase).lowercased()
        var result = body
        var changed = false

        // Walk matches right-to-left so byte offsets stay valid across splices.
        for match in matches.reversed() {
            let fullRange = match.range

            // Skip matches inside code spans/fences.
            if codeRanges.contains(where: { NSIntersectionRange($0, fullRange).length > 0 }) {
                continue
            }

            let targetRange = match.range(at: 1)
            let target = ns.substring(with: targetRange) as NSString

            // Only `source:` links are rewritten. classify() peels the prefix
            // off the (normalized) start, so `page:source:foo` stays untouched.
            let (kind, _) = WikiLinkParser.classify(WikiText.normalized(target as String))
            guard kind == .source else { continue }

            // The splice range starts right after the `source:` prefix
            // (classify confirmed it's at the start, modulo whitespace).
            let prefix = target.range(of: "source:", options: [.caseInsensitive])
            guard prefix.location != NSNotFound else { continue }
            let start = prefix.location + prefix.length
            guard start < target.length else { continue }

            // Candidate name ends, longest slice first: end-of-target (no
            // fragment), then each `#` from rightmost to leftmost.
            var ends: [Int] = [target.length]
            var i = target.length - 1
            while i > start {
                if target.character(at: i) == hashChar { ends.append(i) }
                i -= 1
            }

            for end in ends {
                let slice = WikiText.normalized(
                    target.substring(with: NSRange(location: start, length: end - start)))
                let isOld = slice.lowercased() == normalizedOld
                // Neither the old name nor any other known name — keep trying
                // shorter readings of this span.
                guard isOld || isNameKnown(slice) else { continue }
                // A longer KNOWN name owns this span (longest-name-wins, same
                // rule as WikiLinkResolver) — leave the span untouched.
                guard isOld else { break }

                let absolute = NSRange(location: targetRange.location + start,
                                       length: end - start)
                let mutable = NSMutableString(string: result)
                mutable.replaceCharacters(in: absolute, with: newBase)
                result = mutable as String
                changed = true
                break
            }
        }

        return changed ? result : nil
    }

    private static let hashChar: unichar = 0x23 // #
}
