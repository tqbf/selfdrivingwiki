import Foundation

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
    private static let definitionPattern = #"^\s{0,3}\[\^([^\]\s]+)\]:\s?(.*)$"#
    private static let definitionRegex = try! NSRegularExpression(pattern: definitionPattern)

    public static func rendered(_ markdown: String) -> Rendered {
        let extraction = extractDefinitions(from: markdown)
        let numberedIDs = orderedReferencedIDs(in: extraction.bodyMarkdown, knownIDs: extraction.definitions.keys)
        let numbersByID = Dictionary(uniqueKeysWithValues: numberedIDs.enumerated().map { index, id in
            (id, index + 1)
        })
        let body = rewriteReferences(in: extraction.bodyMarkdown, numbersByID: numbersByID)
        let footnotes = numberedIDs.compactMap { id -> Footnote? in
            guard let markdown = extraction.definitions[id] else { return nil }
            return Footnote(id: id, number: numbersByID[id] ?? 0, markdown: markdown)
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

    // MARK: - Definitions

    private struct Extraction {
        var bodyMarkdown: String
        var definitions: [String: String]
    }

    private struct Line {
        var text: String
        var isProtected: Bool
    }

    private static func extractDefinitions(from markdown: String) -> Extraction {
        let lines = protectedLines(in: markdown)
        var bodyLines: [String] = []
        var definitions: [String: String] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard !line.isProtected, let definition = parseDefinitionLine(line.text) else {
                bodyLines.append(line.text)
                index += 1
                continue
            }

            var definitionLines = [definition.markdown]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if next.isProtected || !isContinuationLine(next.text) {
                    break
                }
                definitionLines.append(trimContinuationPrefix(next.text))
                index += 1
            }

            definitions[definition.id] = definitionLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return Extraction(bodyMarkdown: bodyLines.joined(separator: "\n"), definitions: definitions)
    }

    private static func parseDefinitionLine(_ line: String) -> (id: String, markdown: String)? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = definitionRegex.firstMatch(in: line, range: range) else { return nil }
        let id = ns.substring(with: match.range(at: 1))
        let markdown = ns.substring(with: match.range(at: 2))
        return (id, markdown)
    }

    private static func isContinuationLine(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func trimContinuationPrefix(_ line: String) -> String {
        if line.hasPrefix("    ") {
            return String(line.dropFirst(4))
        }
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        return line
    }

    // MARK: - References

    private static func orderedReferencedIDs(in markdown: String, knownIDs: Dictionary<String, String>.Keys) -> [String] {
        let ns = markdown as NSString
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: markdown)
        let matches = referenceRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var ids: [String] = []

        for match in matches where !WikiLinkSpan.isProtected(match.range, by: codeRanges) {
            let id = ns.substring(with: match.range(at: 1))
            guard knownIDs.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            ids.append(id)
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

    private static func protectedLines(in body: String) -> [Line] {
        let rawLines = body.components(separatedBy: "\n")
        var lines: [Line] = []
        var isInFence = false

        for rawLine in rawLines {
            let isFence = rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            let protected = isInFence || isFence
            lines.append(Line(text: rawLine, isProtected: protected))
            if isFence {
                isInFence.toggle()
            }
        }
        return lines
    }

    // protectedCodeRanges, isInside, and backtick live in WikiLinkSpan (shared).
}
