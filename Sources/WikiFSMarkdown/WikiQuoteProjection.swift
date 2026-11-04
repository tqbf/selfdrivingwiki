import Foundation
import WikiFSLinks

// MARK: - Quote projection + comparison policy
//
// The contract: mirror what the production reader can actually match. The
// reader's navigation (`WikiReaderRep.highlightJS`) walks the RENDERED DOM,
// normalizes typography on both sides (curly quotes, dashes, ellipsis,
// ligatures), lowercases, collapses whitespace, searches the whole-quote as
// a contiguous substring, and falls back to the longest contiguous run of
// >= 4 quote words. It does NOT strip authored Markdown from the quote and
// it does not know about emphasis markup.
//
// This policy answers, WITHOUT a web view: "if the reader opened this source
// and searched this quote, what would it find?" — by projecting the source
// markdown to the visible text its DOM would carry and applying the same
// comparison the highlight JS applies.
//
// Honesty rules:
// - Constructs the pure projection cannot confidently represent (block HTML,
//   images, references it would have to resolve) make the result
//   `.unavailable` — the caller reports an unverified citation rather than a
//   false verdict.
// - Emphasis delimiters are removed only where they form plausible emphasis
//   pairs with flanking constraints. A `*` or `_` in an identifier or literal
//   text is kept, because removing it would change the text.

public enum WikiQuoteProjection {

    /// The projection outcome for one source text.
    public struct Projection: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// `text` is the projected visible text (pre-casefold; the
            /// comparison applies the reader's normalization).
            case text
            /// The projection cannot represent this content; any verdict
            /// would be unreliable.
            case unavailable
        }

        public let state: State
        public let text: String
        public let reason: String?

        public static func text(_ text: String) -> Projection {
            Projection(state: .text, text: text, reason: nil)
        }

        public static func unavailable(_ reason: String) -> Projection {
            Projection(state: .unavailable, text: "", reason: reason)
        }
    }

    /// What the reader's search would do with `quote` against `projection`.
    public enum ComparisonOutcome: Equatable, Sendable {
        /// The whole quote is present contiguously — the reader would
        /// highlight the full quote.
        case fullMatch
        /// Only a partial anchor matches — the reader falls back to the
        /// longest contiguous run of >= 4 quote words (`highlightJS`'s
        /// documented behavior). Navigation happens, but it is NOT the
        /// whole quote.
        case partialMatch
        /// Neither the quote nor any >= 4-word run appears.
        case noMatch
        /// The evidence itself is not usable (projection unavailable, or the
        /// quote is empty after normalization — the reader's search is a
        /// no-op for an empty needle).
        case unavailable
    }

    // MARK: - Projection

    /// Project markdown to the visible text the reader's DOM would carry.
    public static func project(_ markdown: String) -> Projection {
        var unavailableReason: String?
        var out: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        var inFence = false
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence {
                    inFence = true
                } else {
                    inFence = false
                }
                index += 1
                continue
            }
            if inFence {
                // Code block text IS visible text in the reader.
                out.append(projectInline(line).text)
                index += 1
                continue
            }
            if let reason = blockUnsupportedMarker(in: line) {
                // Conservative: block constructs we do not model make the
                // whole projection unreliable.
                unavailableReason = reason
                break
            }
            out.append(projectBlockLine(line))
            index += 1
        }
        if let reason = unavailableReason {
            return .unavailable(reason)
        }
        return .text(out.joined(separator: "\n"))
    }

    /// Block-level constructs the projection refuses to guess at. Returns
    /// the reason when the line introduces one.
    private static func blockUnsupportedMarker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<") {
            let tag = trimmed.dropFirst()
            for name in ["table", "div", "p", "ul", "ol", "pre", "img", "iframe", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"] where tag.lowercased().hasPrefix(name) {
                return "block HTML <\(name)> is not projected"
            }
        }
        if trimmed.hasPrefix("![") { return "image syntax is not projected" }
        if trimmed.hasPrefix("[^") && trimmed.contains("]:") {
            return "footnote definition blocks are not projected"
        }
        return nil
    }

    /// Project one non-fence line: strip block markers, then inline syntax.
    private static func projectBlockLine(_ line: String) -> String {
        var text = line
        // Heading markers.
        if let first = text.first, first == "#" {
            let marker = text.prefix(while: { $0 == "#" })
            if marker.count <= 6, text.count > marker.count,
               text[text.index(text.startIndex, offsetBy: marker.count)] == " " {
                text = String(text.dropFirst(marker.count + 1))
            }
        }
        // Blockquote markers (repeated, one level at a time).
        while text.hasPrefix(">") { text = String(text.dropFirst()) }
        // List markers.
        for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
        }
        if let range = text.range(of: #"^\d{1,9}[.)] "#, options: .regularExpression) {
            text = text.replacingCharacters(in: range, with: "")
        }
        return projectInline(text).text
    }

    /// Project inline syntax of one line. Never throws; unknown constructs
    /// pass through conservatively (kept, not invented). Public so the lint
    /// layer projects QUOTE text with the same rules as source text.
    public static func projectInline(_ line: String) -> Projection {
        var text = line

        // 1. Strip wiki links, keeping the visible alias/target text (the
        //    reader renders the display text, not the brackets). Ranges are
        //    UTF-8 byte offsets — convert through the UTF-8 view, clamped.
        for node in WikiLinkParser.syntaxNodes(in: text).reversed() {
            let displayText: String
            switch node {
            case .link(let link): displayText = link.displayText
            case .embed(let embed): displayText = embed.displayText
            }
            let utf8 = text.utf8
            guard node.sourceRange.upperBound <= utf8.count else { continue }
            let lower = utf8.index(utf8.startIndex, offsetBy: node.sourceRange.lowerBound)
            let upper = utf8.index(lower, offsetBy: node.sourceRange.count)
            guard lower <= upper, upper <= text.endIndex else { continue }
            text.replaceSubrange(lower..<upper, with: displayText)
        }

        // 2. Inline code spans: the reader renders their content as text.
        //    (Protected ranges were respected above for wiki links; here the
        //    backticks are the code delimiter itself.)
        text = replaceGrouped(text, pattern: #"`([^`\n]+)`"#, template: "$1")

        // 3. Images: alt text is not reliably visible text — refuse.
        if text.range(of: #"!\[[^\]]*\]\([^)]*\)"#, options: .regularExpression) != nil {
            return .unavailable("image syntax is not projected")
        }
        // 4. Links: visible text only.
        text = replaceGrouped(text, pattern: #"\[([^\]]+)\]\([^)]*\)"#, template: "$1")
        // Reference-style links: `[text][ref]` → text.
        text = replaceGrouped(text, pattern: #"\[([^\]]+)\]\[[^\]]*\]"#, template: "$1")

        // 5. HTML entities (the reader's DOM carries decoded characters).
        text = HTMLEntities.decode(text)

        // 6. Inline HTML tags: strip tag syntax, keep inner text. A block
        //    tag makes the projection unavailable (checked by the caller).
        if blockInlineHTMLTag(in: text) != nil {
            return .unavailable("HTML block element is not projected")
        }
        text = replaceGrouped(text, pattern: #"</?[A-Za-z][A-Za-z0-9]*(\s[^<>]*)?/?>"#, template: "")

        // 7. Emphasis with flanking constraints. Paired runs only; literals
        //    and identifiers keep their markers.
        text = stripEmphasis(in: text)

        // 8. Backslash escapes: the escaped character is what renders.
        text = text.replacingOccurrences(
            of: #"\\([\\`*_{}\[\]()#+\-.!>~|"])"#,
            with: "$1",
            options: .regularExpression)

        // 9. Footnote reference markers render as generated superscript
        //    numbers, not the authored label — a quote containing one can
        //    never match the projected text.
        if text.range(of: #"\[\^[^\]\s]+\]"#, options: .regularExpression) != nil {
            return .unavailable("footnote reference renders as a generated number")
        }

        return .text(text)
    }

    /// A block-level HTML tag appearing mid-line (rare, but the reader
    /// renders it structurally).
    private static func blockInlineHTMLTag(in text: String) -> String? {
        for name in ["table", "div", "pre", "ul", "ol", "p", "img", "iframe"] {
            if text.range(
                of: "<\(name)[\\s>]",
                options: [.regularExpression, .caseInsensitive]) != nil {
                return name
            }
        }
        return nil
    }

    private static func replaceGrouped(_ text: String, pattern: String, template: String) -> String {
        // All patterns are compile-time literals in this file and valid;
        // a failure degrades to the unmodified text.
        // swiftlint:disable:next silent_try_optional
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length),
            withTemplate: template)
    }

    /// Strip paired emphasis runs (strong/em/strikethrough) with flanking
    /// constraints: an opener must be followed by a non-space and its closer
    /// preceded by a non-space; underscore openers/closers must not sit
    /// inside an alphanumeric run (so `snake_case_name` survives).
    static func stripEmphasis(in text: String) -> String {
        var t = text
        // Double markers first so `**bold**` does not degenerate.
        t = replaceGrouped(t, pattern: #"\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*"#, template: "$1")
        t = replaceGrouped(t, pattern: #"(?<![A-Za-z0-9_])__(?=\S)([^_\n]+?)(?<=\S)__(?![A-Za-z0-9_])"#, template: "$1")
        t = replaceGrouped(t, pattern: #"~~(?=\S)([^~\n]+?)(?<=\S)~~"#, template: "$1")
        // Single asterisk: opener/closer flanking, no whitespace against the
        // marker.
        t = replaceGrouped(t, pattern: #"\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*"#, template: "$1")
        // Single underscore: additionally require word-boundary isolation so
        // identifiers keep their underscores.
        t = replaceGrouped(t, pattern: #"(?<![A-Za-z0-9_])_([^_\n]+?)_(?![A-Za-z0-9_])"#, template: "$1")
        return t
    }

    // MARK: - Comparison (mirrors highlightJS)

    /// Typography normalization exactly mirroring the reader's
    /// `normalizeTypography`: editorial punctuation to the ASCII forms the
    /// JS replaces them with, ligatures expanded.
    public static func normalizeTypography(_ s: String) -> String {
        var t = s
        let pairs: [(String, String)] = [
            ("\u{201C}", "\""), ("\u{201D}", "\""),   // “ ”
            ("\u{2018}", "'"), ("\u{2019}", "'"),     // ‘ ’
            ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2012}", "-"),
            ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2015}", "-"),
            ("\u{2212}", "-"),
            ("\u{2026}", "..."),
            ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"),
            ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"),
            ("\u{FB05}", "st"), ("\u{FB06}", "st"),
        ]
        for (from, to) in pairs {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return t
    }

    /// The reader's search view: typography-normalized, lowercased,
    /// whitespace-collapsed.
    public static func searchView(_ s: String) -> String {
        normalizeTypography(s)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Compare `quote` against a projection with the reader's outcomes.
    public static func compare(quote: String, projected: Projection) -> ComparisonOutcome {
        guard projected.state == .text else { return .unavailable }
        let needle = searchView(quote)
        // An empty needle is a no-op in the reader's JS (early return).
        guard !needle.isEmpty else { return .unavailable }
        let haystack = searchView(projected.text)
        if haystack.contains(needle) { return .fullMatch }

        // The >= 4-word longest-run fallback, longest first (the JS tries
        // every L from words.count-1 down to 4 and takes the first hit).
        let words = needle.split(separator: " ").map(String.init)
        guard words.count > 4 else { return .noMatch }
        for length in stride(from: words.count - 1, through: 4, by: -1) {
            for start in 0...(words.count - length) {
                let candidate = words[start..<(start + length)].joined(separator: " ")
                if haystack.contains(candidate) { return .partialMatch }
            }
        }
        return .noMatch
    }

    /// The longest quote-word run (>= 4 words) present in the projected
    /// text, for evidence display. Nil when nothing partial matches.
    public static func longestPartialRun(quote: String, projected: Projection) -> String? {
        guard projected.state == .text else { return nil }
        let needle = searchView(quote)
        let haystack = searchView(projected.text)
        let words = needle.split(separator: " ").map(String.init)
        guard words.count > 4 else { return nil }
        for length in stride(from: words.count - 1, through: 4, by: -1) {
            for start in 0...(words.count - length) {
                let candidate = words[start..<(start + length)].joined(separator: " ")
                if haystack.contains(candidate) { return candidate }
            }
        }
        return nil
    }
}
