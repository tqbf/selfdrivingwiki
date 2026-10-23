import Foundation
import Markdown

/// Code-protection ranges derived from the parsed AST — fenced code blocks,
/// indented code blocks, and inline code spans, as the READER's parser sees
/// them. This replaces heuristic fence scanning for any consumer that must
/// agree with the reader on what is literal code (REQ-42, REQ-46): a span
/// protected here cannot be a live wiki link, a live footnote reference, or
/// active content.
///
/// Ranges are half-open UTF-8 byte offsets into the authored text (the same
/// coordinates as ``MarkdownSourceRange``).
public struct MarkdownCodeProtection: Equatable, Sendable {
    /// Sorted, non-overlapping protected ranges.
    public let ranges: [MarkdownSourceRange]

    public init(ranges: [MarkdownSourceRange]) {
        self.ranges = ranges.sorted()
    }

    /// `true` when the given authored range overlaps any protected range.
    public func protects(_ range: MarkdownSourceRange) -> Bool {
        // Ranges are sorted; binary search for the first candidate that can
        // overlap `range`.
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].upperBound <= range.lowerBound {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low < ranges.count else { return false }
        return ranges[low].intersects(range)
    }

    /// `true` when the given UTF-8 byte offset sits inside protected code.
    public func protects(offset: Int) -> Bool {
        // swiftlint:disable:next silent_try_optional
        if let point = try? MarkdownSourceRange(lowerBound: offset, upperBound: offset + 1) {
            return protects(point)
        }
        return false
    }
}

public extension ParsedMarkdownDocument {
    /// Derive the document's code protection from its own AST.
    var codeProtection: MarkdownCodeProtection {
        Self.codeProtection(for: document, lineTable: lineTable)
    }

    /// AST-derived code protection for a parsed document: walk the tree and
    /// collect the source range of every code block (fenced or indented) and
    /// inline code span.
    static func codeProtection(
        for document: Document,
        lineTable: MarkdownSourceLineTable
    ) -> MarkdownCodeProtection {
        var ranges: [MarkdownSourceRange] = []
        collectCodeRanges(from: document, lineTable: lineTable, into: &ranges)
        return MarkdownCodeProtection(ranges: ranges)
    }

    private static func collectCodeRanges(
        from markup: Markup,
        lineTable: MarkdownSourceLineTable,
        into ranges: inout [MarkdownSourceRange]
    ) {
        if let range = markup.range, let utf8 = lineTable.range(
            startLine: range.lowerBound.line,
            startUTF8Column: range.lowerBound.column,
            endLine: range.upperBound.line,
            endUTF8Column: range.upperBound.column) {
            if markup is CodeBlock || markup is InlineCode {
                ranges.append(utf8)
            }
        }
        for child in markup.children {
            collectCodeRanges(from: child, lineTable: lineTable, into: &ranges)
        }
    }
}
