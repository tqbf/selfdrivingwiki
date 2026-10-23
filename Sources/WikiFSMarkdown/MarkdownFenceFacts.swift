import Foundation
import Markdown

/// Everything lint needs to know about one FENCED code block, derived from
/// the AST's code-block nodes plus a source-slice inspection of the
/// delimiters themselves (the AST does not expose marker characters,
/// delimiter lengths, or the observed closing fence).
///
/// AST ownership stays with the parser: a fact exists only where the
/// reader's parser produced a code block — this is a detail view of AST
/// nodes, never a whole-document fence heuristic.
public struct MarkdownFenceFact: Equatable, Sendable {
    /// The fence's delimiter character.
    public enum Marker: String, Sendable {
        case backtick = "`"
        case tilde = "~"
    }

    /// The delimiter character of the opening fence.
    public let marker: Marker
    /// The opening delimiter run's length (the closing fence must be at
    /// least this long under CommonMark).
    public let length: Int
    /// The trimmed text after the opening delimiter (the info string — a
    /// language tag or rich-render format name).
    public let infoString: String
    /// The literal text on the opening line before the delimiter run —
    /// blockquote markers and list/indent container context (`> `, `  - `).
    public let containerPrefix: String
    /// UTF-8 range of the opening delimiter run itself.
    public let openingRange: MarkdownSourceRange
    /// UTF-8 range of the whole code-block node.
    public let blockRange: MarkdownSourceRange
    /// UTF-8 range of the observed closing delimiter run; `nil` when the
    /// block closes at end-of-file (which is legal CommonMark — an EOF
    /// fence is NOT a defect on its own).
    public let closingRange: MarkdownSourceRange?

    /// `true` when no closing fence line exists before end-of-file.
    public var isClosedAtEndOfFile: Bool { closingRange == nil }
}

public extension ParsedMarkdownDocument {
    /// Fence facts for every fenced code block in the document, in source
    /// order. Indented (non-fenced) code blocks produce no fact — they carry
    /// no delimiters and are already covered by code protection.
    var fenceFacts: [MarkdownFenceFact] {
        Self.fenceFacts(for: document, source: sourceMarkdown, lineTable: lineTable)
    }

    static func fenceFacts(
        for document: Document,
        source: String,
        lineTable: MarkdownSourceLineTable
    ) -> [MarkdownFenceFact] {
        var blocks: [CodeBlock] = []
        collectCodeBlocks(from: document, into: &blocks)
        let lines = Self.authoredLines(of: source)
        var facts: [MarkdownFenceFact] = []
        for block in blocks {
            guard let blockSourceRange = block.range,
                  let blockRange = lineTable.range(
                    startLine: blockSourceRange.lowerBound.line,
                    startUTF8Column: blockSourceRange.lowerBound.column,
                    endLine: blockSourceRange.upperBound.line,
                    endUTF8Column: blockSourceRange.upperBound.column)
            else { continue }
            // Line indices overlapping the block's byte range.
            let blockLines = lines.indices.filter {
                lines[$0].utf8Range.upperBound > blockRange.lowerBound
                    && lines[$0].utf8Range.lowerBound < blockRange.upperBound
            }
            guard let first = blockLines.first else { continue }
            let opening = Self.parseOpeningFence(line: lines[first].text, lineLower: lines[first].utf8Range.lowerBound)
            guard let opening else { continue } // indented code block — no delimiters

            // Scan for the closing fence: same marker, at least the opening
            // length, nothing after it but spaces, under the same container
            // prefix. Limited to the block's own lines.
            var closing: (range: MarkdownSourceRange, lineIndex: Int)?
            if blockLines.count > 1 {
                for index in blockLines.dropFirst() {
                    if let range = Self.parseClosingFence(
                        line: lines[index].text,
                        lineLower: lines[index].utf8Range.lowerBound,
                        containerPrefix: opening.containerPrefix,
                        marker: opening.marker,
                        minimumLength: opening.length) {
                        closing = (range, index)
                        break
                    }
                }
            }
            _ = closing?.lineIndex
            facts.append(MarkdownFenceFact(
                marker: opening.marker,
                length: opening.length,
                infoString: opening.infoString,
                containerPrefix: opening.containerPrefix,
                openingRange: opening.range,
                blockRange: blockRange,
                closingRange: closing?.range))
        }
        return facts
    }

    private static func collectCodeBlocks(from markup: Markup, into blocks: inout [CodeBlock]) {
        if let codeBlock = markup as? CodeBlock {
            blocks.append(codeBlock)
        }
        for child in markup.children {
            collectCodeBlocks(from: child, into: &blocks)
        }
    }

    // MARK: - Source-slice helpers

    typealias AuthoredLine = (text: Substring, utf8Range: MarkdownSourceRange)

    /// A half-open UTF-8 range that never throws — every call site constructs
    /// it from ordered, in-bounds byte offsets; the degenerate fallback is a
    /// zero-length range at the origin.
    static func safeRange(_ lower: Int, _ upper: Int) -> MarkdownSourceRange {
        do {
            return try MarkdownSourceRange(lowerBound: lower, upperBound: upper)
        } catch {
            return zeroRange
        }
    }

    /// The zero-length range at the origin — a valid `MarkdownSourceRange`
    /// by construction (0 ≤ 0).
    static let zeroRange = forceRange(lowerBound: 0, upperBound: 0)

    private static func forceRange(lowerBound: Int, upperBound: Int) -> MarkdownSourceRange {
        do {
            return try MarkdownSourceRange(lowerBound: lowerBound, upperBound: upperBound)
        } catch {
            fatalError("MarkdownSourceRange(\(lowerBound), \(upperBound)) rejected valid bounds: \(error)")
        }
    }

    /// Split the source into lines, carrying each line's half-open UTF-8 byte
    /// range (the newline excluded).
    static func authoredLines(of source: String) -> [AuthoredLine] {
        func lineRange(_ lower: Int, _ upper: Int) -> MarkdownSourceRange {
            safeRange(lower, upper)
        }
        let utf8 = Array(source.utf8)
        var lines: [AuthoredLine] = []
        var start = 0
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x0A {
                lines.append(AuthoredLine(
                    text: Substring(String(decoding: utf8[start..<index], as: UTF8.self)),
                    utf8Range: lineRange(start, index)))
                start = index + 1
            }
            index += 1
        }
        if start < utf8.count || start == 0 {
            lines.append(AuthoredLine(
                text: Substring(String(decoding: utf8[start..<utf8.count], as: UTF8.self)),
                utf8Range: lineRange(start, utf8.count)))
        }
        return lines
    }

    private struct OpeningFence {
        let marker: MarkdownFenceFact.Marker
        let length: Int
        let infoString: String
        let containerPrefix: String
        let range: MarkdownSourceRange
    }

    /// Parse one line as a fenced-block opening: `[container prefix][0–3
    /// spaces][```|~~~][info string]`. Returns nil for indented code blocks
    /// (no delimiter run).
    private static func parseOpeningFence(line: Substring, lineLower: Int) -> OpeningFence? {
        let bytes = Array(line.utf8)
        var index = 0

        // Container prefix: blockquote markers (`>`) with the whitespace that
        // follows them, plus the list/indent spaces before the fence. The
        // prefix is whatever literal container text precedes the delimiter
        // run; detectors interpret it, the fence math only needs the bytes.
        var prefixEnd = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3E { // '>'
                index += 1
                // One optional space after each '>' is part of the container.
                if index < bytes.count, bytes[index] == 0x20 { index += 1 }
                prefixEnd = index
                continue
            }
            if byte == 0x20 || byte == 0x09 { // space / tab
                index += 1
                continue
            }
            break
        }
        // Only 0–3 of the immediately-preceding spaces may be fence
        // indentation after the container markers; a deeper indent is an
        // indented code block. Approximation that keeps CommonMark behavior
        // for the common cases: recount spaces between prefixEnd and index.
        let indentSpaces = index - prefixEnd
        let isFenceIndent = indentSpaces <= 3
        let marker = index < bytes.count ? bytes[index] : 0
        guard isFenceIndent, marker == 0x60 || marker == 0x7E else { return nil } // ` or ~

        let markerStart = index
        while index < bytes.count, bytes[index] == marker {
            index += 1
        }
        let length = index - markerStart
        guard length >= 3 else { return nil }

        let info = String(decoding: bytes[index...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A backtick fence's info string may not contain backticks (CommonMark) —
        // such a line is prose, not a fence opener.
        if marker == 0x60, info.contains("`") { return nil }

        let range = safeRange(lineLower + markerStart, lineLower + index)
        return OpeningFence(
            marker: marker == 0x60 ? .backtick : .tilde,
            length: length,
            infoString: info,
            containerPrefix: String(decoding: bytes[0..<prefixEnd], as: UTF8.self),
            range: range)
    }

    /// Parse one line as the closing fence for an opening: the same container
    /// prefix, up to 3 spaces, the same marker repeated at least
    /// `minimumLength` times, then nothing but optional whitespace.
    private static func parseClosingFence(
        line: Substring,
        lineLower: Int,
        containerPrefix: String,
        marker: MarkdownFenceFact.Marker,
        minimumLength: Int
    ) -> MarkdownSourceRange? {
        let prefixBytes = Array(containerPrefix.utf8)
        let bytes = Array(line.utf8)
        guard bytes.count >= prefixBytes.count,
              Array(bytes[0..<prefixBytes.count]) == prefixBytes else { return nil }

        var index = prefixBytes.count
        var indent = 0
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 {
            index += 1
            indent += 1
        }
        guard indent <= 3 else { return nil }
        let markerByte: UInt8 = marker == .backtick ? 0x60 : 0x7E
        let markerStart = index
        while index < bytes.count, bytes[index] == markerByte {
            index += 1
        }
        guard index - markerStart >= minimumLength else { return nil }
        // Nothing after the closing run but optional whitespace (space, tab,
        // and a CRLF carriage return — lines split on `\n` keep their `\r`).
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D {
            index += 1
        }
        guard index == bytes.count else { return nil }
        return safeRange(lineLower + markerStart, lineLower + index)
    }
}
