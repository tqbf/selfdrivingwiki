import Foundation
import Markdown

/// Preview-only support for Markdown-style footnotes in wiki pages.
///
/// Foundation's `AttributedString(markdown:)` does not render footnotes, so the
/// app handles the wiki source form:
///
///     Body text with a note[^note-id].
///
///     [^note-id]: Footnote body.
///
/// The source remains unchanged in SQLite and on the mounted filesystem. This
/// transform only prepares content for the in-app reader.
///
/// Extraction runs on the shared, occurrence-preserving footnote analysis
/// (`MarkdownFootnoteAnalysis`) with AST-derived code protection, so the
/// reader and lint pre-flight agree on what is a live footnote and what is
/// literal code (REQ-46).
public enum WikiFootnoteMarkdown {

    public struct Footnote: Equatable, Sendable {
        public let id: String
        public let number: Int
        public let markdown: String

        public init(id: String, number: Int, markdown: String) {
            self.id = id
            self.number = number
            self.markdown = markdown
        }
    }

    public struct Rendered: Equatable, Sendable {
        public let bodyMarkdown: String
        public let footnotes: [Footnote]
    }

    /// The private scheme used for generated footnote reference links. The
    /// reader handles these locally so the system does not try to open them.
    public static let scheme = "wiki-footnote"

    private static let referencePattern = #"\[\^([^\]\s]+)\]"#
    private static let referenceRegex = try! NSRegularExpression(pattern: referencePattern)

    public static func rendered(_ markdown: String) -> Rendered {
        // AST-derived protection: parse the AUTHORED text with the reader's
        // parser and protect what it reports as code (fences, indented blocks,
        // inline spans). The footnote transform then rewrites only live notes.
        let parsed = ParsedMarkdownDocument(parsing: markdown)
        let analysis = MarkdownFootnoteAnalysis.analyze(
            in: markdown,
            protectedRanges: Self.utf16Ranges(of: parsed.codeProtection, in: markdown))

        let bodyAfterDefinitions = removeDefinitions(from: markdown, definitions: analysis.definitions)
        let numberedIDs = orderedReferencedIDs(in: analysis, definedIDs: Set(analysis.definitions.map(\.id)))
        let numbersByID = Dictionary(uniqueKeysWithValues: numberedIDs.enumerated().map { index, id in
            (id, index + 1)
        })
        let body = rewriteReferences(in: bodyAfterDefinitions, numbersByID: numbersByID)
        let footnotes = numberedIDs.compactMap { id -> Footnote? in
            guard let definitionMarkdown = analysis.definitions.first(where: { $0.id == id })?.markdown else {
                return nil
            }
            return Footnote(id: id, number: numbersByID[id] ?? 0, markdown: definitionMarkdown)
        }
        return Rendered(bodyMarkdown: body, footnotes: footnotes)
    }

    public static func isFootnoteURL(_ url: URL) -> Bool {
        url.scheme == scheme
    }

    /// The HTML element id for a footnote definition, used both as the
    /// definition's anchor (`<a id="…">`, injected by `ReaderMarkdown`) and as
    /// the reference link's fragment target (`#…`, emitted by
    /// `rewriteReferences`). WKWebView scrolls to the matching `id` natively when
    /// the fragment is clicked — no JS needed.
    ///
    /// Built with a stable percent-encoding so the fragment and the element id
    /// always agree (the id can contain spaces / punctuation).
    public static func footnoteAnchorID(for id: String) -> String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: titleQueryAllowed) ?? id
        return "wiki-fn-\(encoded)"
    }

    // MARK: - Definition removal (reader body preparation)

    /// Remove every definition occurrence's lines from the source, leaving
    /// the body the reader renders. Line-join semantics match the
    /// historical extractor byte-for-byte: split on `\n`, drop the lines a
    /// definition span occupies, join the remainder.
    private static func removeDefinitions(
        from source: String,
        definitions: [MarkdownFootnoteAnalysis.Definition]
    ) -> String {
        guard !definitions.isEmpty else { return source }
        let lines = source.components(separatedBy: "\n")
        // Walk line offsets; mark lines a definition span (UTF-16) covers.
        var coveredLineIndices = Set<Int>()
        var offset = 0
        var sortedDefinitions = definitions.sorted { $0.utf16Range.location < $1.utf16Range.location }
        for (index, line) in lines.enumerated() {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: offset, length: lineLength)
            while let first = sortedDefinitions.first,
                  first.utf16Range.location + first.utf16Range.length <= offset {
                sortedDefinitions.removeFirst()
            }
            if let first = sortedDefinitions.first,
               NSIntersectionRange(first.utf16Range, lineRange).length > 0 {
                coveredLineIndices.insert(index)
            }
            offset += lineLength + 1
        }
        guard !coveredLineIndices.isEmpty else { return source }
        return lines.enumerated()
            .filter { !coveredLineIndices.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
    }

    /// Numbering order: referenced (and defined) IDs in first-reference order.
    private static func orderedReferencedIDs(
        in analysis: MarkdownFootnoteAnalysis,
        definedIDs: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for reference in analysis.references where definedIDs.contains(reference.id) {
            if seen.insert(reference.id).inserted {
                ids.append(reference.id)
            }
        }
        return ids
    }

    private static func rewriteReferences(in markdown: String, numbersByID: [String: Int]) -> String {
        let ns = markdown as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: markdown)
        let matches = referenceRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))

        var output = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            if codeRanges.contains(where: { NSIntersectionRange($0, full).length > 0 }) {
                continue
            }

            let id = ns.substring(with: match.range(at: 1))
            guard let number = numbersByID[id] else { continue }

            if full.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            }
            cursor = full.location + full.length

            // A same-page fragment link (`#wiki-fn-<id>`) — WKWebView scrolls to
            // the matching definition anchor natively, with no JS or delegate
            // dependency. (Custom-scheme links aren't reliably routed through
            // WKWebView's navigation policy for same-document scrolls.)
            output += "[\(superscript(number))](#\(footnoteAnchorID(for: id)))"
        }

        if cursor < ns.length {
            output += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        }
        return output
    }

    private static let titleQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?#+ ")
        return set
    }()

    private static func superscript(_ number: Int) -> String {
        String(number).map { digit in
            switch digit {
            case "0": "⁰"
            case "1": "¹"
            case "2": "²"
            case "3": "³"
            case "4": "⁴"
            case "5": "⁵"
            case "6": "⁶"
            case "7": "⁷"
            case "8": "⁸"
            case "9": "⁹"
            default: String(digit)
            }
        }.joined()
    }

    // MARK: - Protected code ranges

    /// Convert AST-derived UTF-8 protection ranges into the UTF-16 offsets the
    /// NSString-based rewrite helpers use. Public so lint pre-flight (and any
    /// other WikiFSCore consumer) shares one conversion.
    public static func utf16Ranges(of protection: MarkdownCodeProtection, in source: String) -> [NSRange] {
        protection.ranges.compactMap { range in
            guard let lower = source.utf8.index(source.utf8.startIndex, offsetBy: range.lowerBound, limitedBy: source.utf8.endIndex),
                  let upper = source.utf8.index(source.utf8.startIndex, offsetBy: range.upperBound, limitedBy: source.utf8.endIndex),
                  let lowerUTF16 = lower.samePosition(in: source.utf16),
                  let upperUTF16 = upper.samePosition(in: source.utf16) else {
                return nil
            }
            let location = source.utf16.distance(from: source.utf16.startIndex, to: lowerUTF16)
            let length = source.utf16.distance(from: lowerUTF16, to: upperUTF16)
            return NSRange(location: location, length: length)
        }
    }

    // protectedCodeRanges, isInside, and backtick live in WikiLinkSpan (shared).
}
