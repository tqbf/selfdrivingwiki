import Foundation
import WikiFSLinks

// MARK: - Footnote analysis (lint-facing value API)
//
// Shares the parsing rules of `WikiFootnoteMarkdown.rendered` (same regexes,
// same fence protection, same continuation-line grammar) so the analysis
// reports on exactly what the reader renders. This API never rewrites
// footnotes — it reports authored occurrences with their exact ranges so the
// lint layer can classify undefined references, conflicting duplicates,
// identical duplicates, and unused definitions.
//
// Protected examples (fenced code, inline code) are preserved as authored
// occurrences but flagged `inProtectedExample` — lint never reports them.

public enum WikiFootnoteAnalysis {

    /// One authored `[^label]` reference occurrence.
    public struct Reference: Hashable, Sendable {
        public let label: String
        /// Validated UTF-8 byte range of the whole `[^label]` text.
        public let range: MarkdownSourceRange
        public let inProtectedExample: Bool
    }

    /// One authored `[^label]: …` definition (with continuation lines).
    public struct Definition: Hashable, Sendable {
        public let label: String
        /// The normalization used to group duplicate labels: trimmed,
        /// whitespace-collapsed, lowercased.
        public let normalizedLabel: String
        /// The definition's markdown content (continuation lines joined —
        /// what `rendered` would render), trimmed.
        public let markdown: String
        /// Validated UTF-8 byte range of the definition's first line (the
        /// safe repair deletes whole blocks; the range anchors the finding).
        public let range: MarkdownSourceRange
        /// Validated UTF-8 byte range of the WHOLE block: first line through
        /// its last continuation line, including the trailing newline when
        /// one follows (so deleting the block removes its line cleanly).
        public let blockRange: MarkdownSourceRange
    }

    /// The complete authored occurrence set.
    public struct Result: Sendable, Equatable {
        public let references: [Reference]
        public let definitions: [Definition]

        /// References whose label has no definition (outside protected
        /// examples). Authored occurrences, in order.
        public var undefinedReferences: [Reference] {
            let labels = Set(definitions.map { normalizedLabel(of: $0.label) })
            return references.filter {
                !$0.inProtectedExample && !labels.contains(normalizedLabel(of: $0.label))
            }
        }

        /// Labels defined more than once (outside protected examples),
        /// grouped in first-authored order.
        public var duplicateGroups: [[Definition]] {
            let visible = definitions
            let counts = Dictionary(grouping: visible, by: \.normalizedLabel)
            var groups: [[Definition]] = []
            var seen = Set<String>()
            for definition in visible {
                guard seen.insert(definition.normalizedLabel).inserted else { continue }
                let group = counts[definition.normalizedLabel] ?? []
                if group.count > 1 { groups.append(group) }
            }
            return groups
        }

        /// Definitions no reference points at (outside protected examples).
        public var unusedDefinitions: [Definition] {
            let referenced = Set(references.filter { !$0.inProtectedExample }.map {
                normalizedLabel(of: $0.label)
            })
            return definitions.filter { !referenced.contains($0.normalizedLabel) }
        }
    }

    /// The label normalization used across references and definitions.
    public static func normalizedLabel(of label: String) -> String {
        label.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Analyze every authored footnote occurrence in `body`.
    public static func analyze(_ body: String) -> Result {
        let ns = body as NSString
        let lines = WikiFootnoteMarkdown.protectedLines(in: body)
        let codeRanges = WikiLinkSpan.protectedCodeRanges(in: body)

        // Pass 1: definitions (with continuation lines) + their ranges.
        var definitions: [Definition] = []
        var definitionLineIndexes = Set<Int>()
        var index = 0
        var cursorUTF16 = 0
        var lineUTF16: [Int] = []
        for line in lines {
            lineUTF16.append(cursorUTF16)
            cursorUTF16 += (line.text as NSString).length + 1 // + the newline
        }
        func utf8Range(utf16Location: Int, length: Int) -> MarkdownSourceRange? {
            let r = NSRange(location: utf16Location, length: length)
            guard let swiftRange = Range(r, in: body),
                  let lower = swiftRange.lowerBound.samePosition(in: body.utf8),
                  let upper = swiftRange.upperBound.samePosition(in: body.utf8) else {
                return nil
            }
            // The ranges derive from validated UTF-16 matches over the same
            // string; a conversion failure is a parser-contract violation,
            // so the occurrence is dropped from the analysis.
            // swiftlint:disable:next silent_try_optional
            return try? MarkdownSourceRange(
                lowerBound: body.utf8.distance(from: body.utf8.startIndex, to: lower),
                upperBound: body.utf8.distance(from: body.utf8.startIndex, to: upper))
        }

        while index < lines.count {
            let line = lines[index]
            guard !line.isProtected,
                  let parsed = WikiFootnoteMarkdown.parseDefinitionLine(line.text) else {
                index += 1
                continue
            }
            let firstLineIndex = index
            definitionLineIndexes.insert(index)
            var contentLines = [parsed.markdown]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if next.isProtected || !WikiFootnoteMarkdown.isContinuationLine(next.text) {
                    break
                }
                definitionLineIndexes.insert(index)
                contentLines.append(trimContinuationPrefix(next.text))
                index += 1
            }
            let lastLineIndex = index - 1

            let firstStart16 = lineUTF16[firstLineIndex]
            let firstLineLength = (lines[firstLineIndex].text as NSString).length
            let firstRange = utf8Range(
                utf16Location: firstStart16, length: firstLineLength)

            // Block: first line through the last continuation line, plus the
            // trailing newline when one follows (never past the body end).
            let lastStart16 = lineUTF16[lastLineIndex]
            let lastLength = (lines[lastLineIndex].text as NSString).length
            var blockEnd16 = lastStart16 + lastLength
            if blockEnd16 < ns.length { blockEnd16 += 1 } // consume the newline
            let blockRange = utf8Range(
                utf16Location: firstStart16, length: blockEnd16 - firstStart16)

            guard let firstRange, let blockRange else { continue }
            definitions.append(Definition(
                label: parsed.id,
                normalizedLabel: normalizedLabel(of: parsed.id),
                markdown: contentLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                range: firstRange,
                blockRange: blockRange))
        }

        // Pass 2: reference occurrences outside definition lines.
        var references: [Reference] = []
        let matches = WikiFootnoteMarkdown.referenceRegex.matches(
            in: body, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let range16 = match.range
            // Which (unprotected) line does this occurrence start on?
            var lineIndex: Int? = nil
            for (i, start) in lineUTF16.enumerated() {
                let line = lines[i]
                let end = start + (line.text as NSString).length
                if range16.location >= start, range16.location <= end {
                    lineIndex = i
                    break
                }
            }
            guard let lineIndex, !lines[lineIndex].isProtected,
                  !definitionLineIndexes.contains(lineIndex) else { continue }
            // Extract the label via the regex group.
            let labelText = ns.substring(with: match.range(at: 1))
            let inCode = WikiLinkSpan.isProtected(range16, by: codeRanges)
            guard let byteRange = utf8Range(
                utf16Location: range16.location, length: range16.length) else { continue }
            references.append(Reference(
                label: labelText, range: byteRange, inProtectedExample: inCode))
        }

        return Result(references: references, definitions: definitions)
    }

    private static func trimContinuationPrefix(_ line: String) -> String {
        if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        return line
    }
}
