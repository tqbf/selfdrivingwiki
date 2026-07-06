import Foundation

/// Shared regex + code-range detection for `[[wiki-link]]` span processing.
///
/// Extracted from `WikiLinkMarkdown` and `WikiFootnoteMarkdown` (which had
/// copy-pasted `protectedCodeRanges`) so `WikiLinkRewriter` (Phase D) can reuse
/// the same span-locating logic without a third copy.
///
/// This is intentionally a pure dependency-free helper — no store, no SwiftUI.
public enum WikiLinkSpan {

    /// The canonical `[[…]]` bracket-span regex (shared with `WikiLinkParser`,
    /// `WikiLinkMarkdown`). Group 1 = target, group 2 = optional alias.
    ///
    /// Group 1 allows a `]` when it falls inside a `"…"` quoted run (the
    /// `#"quote"` anchor syntax) — `(?:[^\]\|"]|"[^"]*")+` consumes either an
    /// ordinary non-delimiter character, or a whole balanced quoted span in one
    /// bite, so an unbalanced `]` inside the quote (e.g. a bracketed aside like
    /// `[(note)]`) can't terminate the match early (issue #118).
    public static let pattern = #"\[\[((?:[^\]\|"]|"[^"]*")+)(?:\|([^\]]+))?\]\]"#
    public static let regex = try! NSRegularExpression(pattern: pattern)

    // MARK: - Code-range detection

    /// Ranges of `body` inside an inline code span (`` `…` ``) or a fenced code
    /// block (``` ```…``` ```), where `[[…]]` must NOT be processed. Handles the
    /// two CommonMark code forms the preview renders; does NOT model indented
    /// (4-space) code blocks (which the preview's inline-only parse doesn't render
    /// as code anyway).
    public static func protectedCodeRanges(in body: String) -> [NSRange] {
        let ns = body as NSString
        var ranges: [NSRange] = []

        // 1) Fenced blocks: a line starting with ``` opens; the next such line
        //    (or end of text) closes. Whole span (incl. fences) is protected.
        let lines = body.components(separatedBy: "\n")
        var offset = 0
        var fenceStart: Int? = nil
        for line in lines {
            let lineLen = (line as NSString).length
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFence {
                if let start = fenceStart {
                    ranges.append(NSRange(location: start, length: (offset + lineLen) - start))
                    fenceStart = nil
                } else {
                    fenceStart = offset
                }
            }
            offset += lineLen + 1 // + the "\n" we split on
        }
        if let start = fenceStart {
            ranges.append(NSRange(location: start, length: ns.length - start))
        }

        // 2) Inline code spans: backtick runs of length N delimit a span that
        //    closes on the next run of exactly N backticks.
        var i = 0
        while i < ns.length {
            if isInside(i, ranges) { i += 1; continue }
            if ns.character(at: i) == backtick {
                var runLen = 0
                while i + runLen < ns.length, ns.character(at: i + runLen) == backtick { runLen += 1 }
                let spanOpen = i
                var j = i + runLen
                var closed = false
                while j < ns.length {
                    if ns.character(at: j) == backtick {
                        var closeLen = 0
                        while j + closeLen < ns.length, ns.character(at: j + closeLen) == backtick { closeLen += 1 }
                        if closeLen == runLen {
                            ranges.append(NSRange(location: spanOpen, length: (j + closeLen) - spanOpen))
                            i = j + closeLen
                            closed = true
                            break
                        }
                        j += closeLen
                    } else {
                        j += 1
                    }
                }
                if !closed { i = spanOpen + runLen }
            } else {
                i += 1
            }
        }
        return ranges
    }

    /// True when `index` falls inside any of `ranges`.
    public static func isInside(_ index: Int, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(index, $0) }
    }

    /// True when `span` (a `[[…]]` or `[^id]` match) should be treated as
    /// literal code, because it is nested INSIDE a code span/fence — i.e. a
    /// code range that starts at or before `span` and ends at or after it.
    ///
    /// A plain `NSIntersectionRange(...).length > 0` check (the original
    /// implementation) can't distinguish that case from the reverse nesting —
    /// a code span written INSIDE a link's anchor text, e.g. a citation quoting
    /// `` `.minimize` `` — which also has non-zero intersection but should NOT
    /// suppress the link (issue #117). Full containment is unambiguous: only
    /// the code-outside-link case satisfies it.
    public static func isProtected(_ span: NSRange, by codeRanges: [NSRange]) -> Bool {
        codeRanges.contains { codeRange in
            codeRange.location <= span.location
                && (codeRange.location + codeRange.length) >= (span.location + span.length)
        }
    }

    private static let backtick: unichar = 0x60 // `
    private static let bang: unichar = 0x21     // !
    private static let backslash: unichar = 0x5C // \

    // MARK: - Embed prefix detection

    /// True when a `!` immediately precedes the `[[` at `range.location`, making
    /// the span an embed (`![[…]]`, Obsidian syntax). Guards against escaped
    /// (`\![[`) and double-bang (`!![[`) forms so only a clean `![[` run counts:
    ///   * `range.location > 0` and the char at `location - 1` is `!`;
    ///   * the char at `location - 2` is NOT `\` (not escaped);
    ///   * the char at `location - 2` is NOT `!` (the bang is the START of the
    ///     `![[` run — a double bang `!![[` is not an embed).
    ///
    /// Shared by `WikiLinkParser.parse()` (sets `isEmbed`) and
    /// `WikiLinkMarkdown.linkified()` (emits embed HTML / consumes the `!`).
    public static func isEmbedPrefix(_ body: NSString, _ range: NSRange) -> Bool {
        guard range.location > 0,
              body.character(at: range.location - 1) == bang else { return false }
        // Not escaped and not double-bang: check location - 2 if it exists.
        if range.location >= 2 {
            let prev = body.character(at: range.location - 2)
            if prev == backslash || prev == bang { return false }
        }
        return true
    }
}
