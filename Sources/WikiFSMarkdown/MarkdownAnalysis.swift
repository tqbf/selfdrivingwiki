import Foundation
import Markdown

/// Canonical 1-based line to UTF-8 byte-offset conversion for Swift Markdown
/// source locations. Extracted from the app's reader so lint pre-flight maps
/// AST source locations onto the same UTF-8 byte coordinates the reader
/// uses — one implementation, no drift.
public struct MarkdownSourceLineTable: Hashable, Sendable {
    private let lineStarts: [Int]
    public let utf8Count: Int

    public init(source: String) {
        let bytes = Array(source.utf8)
        var starts = [0]
        for index in bytes.indices where bytes[index] == 0x0A {
            starts.append(index + 1)
        }
        lineStarts = starts
        utf8Count = bytes.count
    }

    public func offset(line: Int, utf8Column: Int) -> Int? {
        guard line > 0, utf8Column > 0, line <= lineStarts.count else { return nil }
        let value = lineStarts[line - 1] + utf8Column - 1
        let lineEnd = line < lineStarts.count ? lineStarts[line] : utf8Count
        guard value >= lineStarts[line - 1], value <= lineEnd else { return nil }
        return value
    }

    public func range(
        startLine: Int,
        startUTF8Column: Int,
        endLine: Int,
        endUTF8Column: Int
    ) -> MarkdownSourceRange? {
        guard let lowerBound = offset(line: startLine, utf8Column: startUTF8Column),
              let upperBound = offset(line: endLine, utf8Column: endUTF8Column) else {
            return nil
        }
        // swiftlint:disable:next silent_try_optional
        return try? MarkdownSourceRange(lowerBound: lowerBound, upperBound: upperBound)
    }
}

/// The shared parse result: one `Markdown.Document` parsed with the READER's
/// configuration (no extra parse options — the dialect the reader renders),
/// plus the line table that converts AST source locations into authored
/// UTF-8 byte coordinates. Lint pre-flight consumes this so every structural
/// detector shares the renderer's semantics (REQ-46); findings recorded
/// against `sourceMarkdown` stay tied to authored bytes.
/// The Swift Markdown `Document` has no `Sendable` conformance; the wrapper
/// exposes all state immutably and consumers never mutate the AST (the same
/// posture as the reader's `PreparedMarkdownDocument`).
// swiftlint:disable:next unchecked_sendable
public struct ParsedMarkdownDocument: @unchecked Sendable {
    /// The authored text the document was parsed from.
    public let sourceMarkdown: String
    /// The parsed AST. Swift Markdown's `Document` has no `Sendable`
    /// conformance; the wrapper exposes it immutably and consumers never
    /// mutate it (the same posture as the reader's `PreparedMarkdownDocument`).
    public let document: Document
    public let lineTable: MarkdownSourceLineTable

    public init(parsing sourceMarkdown: String) {
        self.sourceMarkdown = sourceMarkdown
        self.document = Document(parsing: sourceMarkdown)
        self.lineTable = MarkdownSourceLineTable(source: sourceMarkdown)
    }

    /// The UTF-8 `MarkdownSourceRange` for an AST node's source range, or nil
    /// when the node carries no source map or the location is outside the
    /// authored bytes.
    public func utf8Range(of sourceRange: SourceRange?) -> MarkdownSourceRange? {
        guard let sourceRange else { return nil }
        return lineTable.range(
            startLine: sourceRange.lowerBound.line,
            startUTF8Column: sourceRange.lowerBound.column,
            endLine: sourceRange.upperBound.line,
            endUTF8Column: sourceRange.upperBound.column)
    }
}
