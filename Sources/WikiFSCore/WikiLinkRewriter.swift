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
    /// The rewrite splices by structure rather than `replaceOccurrences(of:)`:
    /// it finds the bare-target byte range after `source:` and before the first
    /// `#`/`|`, so `[[source:  old base#"quote"|alias]]` correctly matches
    /// `old base` and replaces only the bare target, leaving everything else
    /// byte-for-byte intact.
    public static func rewriteSourceBase(
        in body: String,
        matching oldBase: String,
        to newBase: String
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
            let target = ns.substring(with: targetRange)

            // Split on first `#` (fragment), then classify the base part.
            let (base, _) = WikiLinkParser.splitFragment(target)
            let (kind, bareTarget) = WikiLinkParser.classify(base)

            guard kind == .source else { continue }
            guard WikiText.normalized(bareTarget).lowercased() == normalizedOld else { continue }

            // Find the byte range of `bareTarget` within the original target text.
            // `classify` peels `source:` and normalizes; to get the ORIGINAL
            // un-normalized bare-target slice we find it structurally: after the
            // `source:` prefix and before the first `#` or `|`.
            guard let bareRange = bareTargetRange(in: target, for: bareTarget) else {
                continue
            }

            // Map from target-relative to body-absolute byte offsets.
            let absoluteStart = targetRange.location + bareRange.location
            let absoluteEnd = absoluteStart + bareRange.length

            guard absoluteStart >= 0, absoluteEnd <= ns.length else { continue }

            let mutable = NSMutableString(string: result)
            mutable.replaceCharacters(in: NSRange(location: absoluteStart, length: absoluteEnd - absoluteStart), with: newBase)
            result = mutable as String
            changed = true
        }

        return changed ? result : nil
    }

    /// Within a source-link target string (everything after `[[` and before the
    /// first `|` or `]]`), find the byte range to splice — everything between the
    /// `source:` prefix and the first `#` or `|` (or end of string), including
    /// any whitespace after `source:`. Replacing this whole range with `newBase`
    /// normalizes `source:  old base#frag` → `source:new base#frag`.
    ///
    /// Returns nil if the structural search fails (shouldn't — `classify` already
    /// confirmed a `.source` classification, so `source:` must be present).
    private static func bareTargetRange(
        in target: String,
        for bareTarget: String
    ) -> NSRange? {
        let ns = target as NSString

        // Find end of `source:` prefix (case-insensitive). The splice range
        // starts right after the colon.
        let lower = target.lowercased()
        guard let prefixEnd = lower.range(of: "source:")?.upperBound else { return nil }
        let start = target.distance(from: target.startIndex, to: prefixEnd)
        guard start < ns.length else { return nil }

        // End at the first `#` or `|` after the prefix (or end of string).
        var end = ns.length
        for i in start..<ns.length {
            let c = ns.character(at: i)
            if c == hashChar || c == pipeChar {
                end = i
                break
            }
        }

        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static let hashChar: unichar = 0x23 // #
    private static let pipeChar: unichar = 0x7C // |
}
