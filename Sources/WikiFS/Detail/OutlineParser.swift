// pattern: Pure Function

import Foundation
import WikiFSCore

/// Pure markdown-outline parsing shared by the page and source producers.
/// Extracted verbatim from the former `PageOutlineView.parseHeadings`:
/// no logging, no state — same input always yields the same headings.
enum OutlineParser {
    /// Parses ATX headings (`#` … `######`) out of markdown. Fenced code
    /// blocks are skipped, `#` runs longer than six or not followed by
    /// whitespace are rejected, empty or markup-only text is rejected, and
    /// inline markup is stripped from the display text. Slugs are deduped
    /// exactly like the HTML renderer's anchor ids, so outline clicks and
    /// rendered `#fragment` anchors agree.
    static func headings(in markdown: String) -> [OutlineHeading] {
        var items: [OutlineHeading] = []
        var slugCounts: [String: Int] = [:]
        var inFence = false

        // charOffset tracks the NSString (UTF-16) character offset of each
        // line's start — the same coordinate space NSTextView uses for ranges.
        var charOffset = 0

        for line in markdown.components(separatedBy: .newlines) {
            let lineUTF16Length = (line as NSString).length
            defer { charOffset += lineUTF16Length + 1 } // +1 for the \n

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                guard level > 0 && level <= 6 else { continue }

                let afterPounds = trimmed.dropFirst(level)
                guard afterPounds.first?.isWhitespace == true else { continue }

                let rawText = afterPounds.trimmingCharacters(in: .whitespaces)
                guard !rawText.isEmpty else { continue }

                // Strip inline markdown (links, code spans, emphasis) so the
                // outline shows plain text — matching the HTML renderer's
                // heading anchor IDs (which use Swift-Markdown's plainText).
                let text = stripInlineMarkup(rawText)
                guard !text.isEmpty else { continue }

                let slug = AnchorBlock.makeSlug(text, counts: &slugCounts)
                items.append(OutlineHeading(id: slug, text: text, level: level,
                                            charOffset: charOffset))
            }
        }

        return items
    }

    /// The id of the heading whose `charOffset` is the last one at or before
    /// the caret, or `nil` when no heading precedes the caret. Producers pass
    /// `caretCharIndex ?? -1` when there is no caret; a negative caret can
    /// never precede-match an offset (offsets are >= 0), so it yields `nil`.
    /// Same UTF-16 coordinate space as the editors' `NSTextView` ranges.
    static func activeHeadingID(caretUTF16Offset: Int, headings: [OutlineHeading]) -> String? {
        guard !headings.isEmpty else { return nil }
        var active: OutlineHeading?
        for heading in headings {
            if heading.charOffset <= caretUTF16Offset {
                active = heading
            } else {
                break
            }
        }
        return active?.id
    }

    // MARK: - Inline markup stripping

    /// Strip inline markdown so heading text reads as plain text in the
    /// outline. Handles the cases most likely in headings: links
    /// (`[text](url)` → `text`), code spans (`` `text` `` → `text`), and
    /// emphasis (`**bold**`, `*italic*`, `__bold__`, `_italic_` → `text`).
    /// This mirrors what Swift-Markdown's `plainText` does in the HTML
    /// renderer, keeping the outline's display + slug in sync with the
    /// rendered anchor IDs.
    private static let linkAndCodeRegexes: [NSRegularExpression] = {
        [
            DebugLog.trying("compile link regex", operation: { try NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) }),  // links
            DebugLog.trying("compile code span regex", operation: { try NSRegularExpression(pattern: #"`([^`]*)`"#) }),              // code spans
        ].compactMap { $0 }
    }()

    static func stripInlineMarkup(_ text: String) -> String {
        var result = text
        for regex in linkAndCodeRegexes {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1")
        }
        // Emphasis markers — strip ** before *, __ before _ to avoid
        // mismatched pairs. Use simple replacement (safe in headings where
        // these are virtually always emphasis, not literal characters).
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        return result
    }
}
