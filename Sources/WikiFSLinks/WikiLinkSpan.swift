import Foundation

// pattern: Functional Core

/// Shared wiki-link span parsing + code-range detection.
///
/// Extracted from `WikiLinkMarkdown` and `WikiFootnoteMarkdown` (which had
/// copy-pasted `protectedCodeRanges`) so `WikiLinkRewriter` (Phase D) can reuse
/// the same span-locating logic without a third copy.
///
/// This is intentionally a pure dependency-free helper — no store, no SwiftUI.
public enum WikiLinkSpan {

    /// One parsed `[[target|alias]]` span. Ranges use UTF-16 offsets so they
    /// interoperate with `NSString` replacement APIs used by the Markdown
    /// rewrite pipeline.
    public struct Match: Sendable {
        public let range: NSRange
        public let targetRange: NSRange
        public let aliasRange: NSRange

        /// Mirrors the capture-group API previously supplied by
        /// `NSTextCheckingResult`: group 0 is the complete link, group 1 the
        /// target, and group 2 the optional alias.
        public func range(at index: Int) -> NSRange {
            switch index {
            case 0: range
            case 1: targetRange
            case 2: aliasRange
            default: NSRange(location: NSNotFound, length: 0)
            }
        }
    }

    /// Find all complete `[[…]]` spans in document order.
    ///
    /// This intentionally uses a deterministic scanner instead of a regular
    /// expression. `]]` is always structural: it closes the current link even
    /// if the target has malformed quote-anchor punctuation. Balanced quote runs
    /// only affect whether `|` belongs to a quoted fragment or starts an alias.
    /// That retains issue #118's `]` / `|` quote support while preventing the
    /// #908 malformed `"" ]]` form from consuming later paragraphs.
    public static func matches(in body: String) -> [Match] {
        let text = body as NSString
        var matches: [Match] = []
        var cursor = 0

        while cursor + openingDelimiterLength <= text.length {
            guard text.character(at: cursor) == openingBracket,
                  text.character(at: cursor + 1) == openingBracket else {
                cursor += 1
                continue
            }

            let start = cursor
            let targetStart = start + openingDelimiterLength
            guard let end = closingDelimiter(after: targetStart, in: text) else {
                // An unclosed `[[` is literal text. Resume after its opener so
                // a later independent wiki link can still be found.
                cursor = targetStart
                continue
            }

            var index = targetStart
            var aliasStart: Int?
            while index < end {
                if text.character(at: index) == quote,
                   let quoteEnd = matchingQuote(after: index, before: end, in: text) {
                    index = quoteEnd + 1
                    continue
                }
                if text.character(at: index) == pipe, aliasStart == nil {
                    aliasStart = index
                }
                index += 1
            }

            let targetEnd = aliasStart ?? end
            // Match the former grammar: neither an empty target nor an empty
            // explicit alias is a complete wiki link.
            guard targetEnd > targetStart,
                  aliasStart.map({ $0 + 1 < end }) ?? true else {
                cursor = end + closingDelimiterLength
                continue
            }
            let aliasRange = aliasStart.map {
                NSRange(location: $0 + 1, length: end - $0 - 1)
            } ?? NSRange(location: NSNotFound, length: 0)
            matches.append(Match(
                range: NSRange(location: start, length: end + closingDelimiterLength - start),
                targetRange: NSRange(location: targetStart, length: targetEnd - targetStart),
                aliasRange: aliasRange))
            cursor = end + closingDelimiterLength
        }
        return matches
    }

    /// The first `]]` is always a structural terminator. This intentionally
    /// does not inspect quote state: a stray quote must not change link bounds.
    private static func closingDelimiter(after start: Int, in text: NSString) -> Int? {
        var index = start
        while index + 1 < text.length {
            if text.character(at: index) == closingBracket,
               text.character(at: index + 1) == closingBracket {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Return the next quote before a known link terminator. An unmatched quote
    /// is literal, so malformed data cannot suppress a later alias delimiter.
    private static func matchingQuote(after start: Int, before end: Int, in text: NSString) -> Int? {
        var index = start + 1
        while index < end {
            if text.character(at: index) == quote { return index }
            index += 1
        }
        return nil
    }

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

    /// True when a complete wiki-link expression is immediately wrapped in a
    /// matching run of unescaped backticks. This local check is deliberately
    /// independent of the document-wide code-span pairing: malformed Markdown
    /// earlier in the document must not turn a literal `` `![[source:X]]` ``
    /// example into a live embed.
    public static func isLocallyCodeWrapped(
        _ body: NSString,
        _ span: NSRange,
        includesEmbedPrefix: Bool
    ) -> Bool {
        let expressionStart = includesEmbedPrefix ? span.location - 1 : span.location
        let expressionEnd = span.location + span.length
        guard expressionStart > 0, expressionEnd < body.length else { return false }

        var openingStart = expressionStart
        while openingStart > 0,
              body.character(at: openingStart - 1) == backtick {
            openingStart -= 1
        }
        let openingLength = expressionStart - openingStart
        guard openingLength > 0 else { return false }

        var closingEnd = expressionEnd
        while closingEnd < body.length,
              body.character(at: closingEnd) == backtick {
            closingEnd += 1
        }
        guard closingEnd - expressionEnd == openingLength else { return false }

        var slashCount = 0
        var cursor = openingStart
        while cursor > 0, body.character(at: cursor - 1) == backslash {
            slashCount += 1
            cursor -= 1
        }
        return slashCount.isMultiple(of: 2)
    }

    private static let backtick: unichar = 0x60 // `
    private static let bang: unichar = 0x21     // !
    private static let backslash: unichar = 0x5C // \
    private static let openingBracket: unichar = 0x5B // [
    private static let closingBracket: unichar = 0x5D // ]
    private static let quote: unichar = 0x22 // "
    private static let pipe: unichar = 0x7C // |
    private static let openingDelimiterLength = 2
    private static let closingDelimiterLength = 2

    // MARK: - Embed prefix detection

    /// True when a `!` immediately precedes the `[[` at `range.location`, making
    /// the span an embed (`![[…]]`, Obsidian syntax). Guards against escaped
    /// (`\![[`) and double-bang (`!![[`) forms so only a clean `![[` run counts:
    ///   * `range.location > 0` and the char at `location - 1` is `!`;
    ///   * the char at `location - 2` is NOT `\` (not escaped);
    ///   * the char at `location - 2` is NOT `!` (the bang is the START of the
    ///     `![[` run — a double bang `!![[` is not an embed).
    ///
    /// Shared by `WikiLinkParser.parse()` and the typed Markdown syntax overlay.
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
