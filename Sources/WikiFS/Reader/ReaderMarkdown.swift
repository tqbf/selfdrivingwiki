import Foundation
import Markdown
import WikiFSCore

/// Canonical 1-based line to UTF-8 byte-offset conversion for Swift Markdown
/// source locations.
struct MarkdownSourceLineTable: Hashable, Sendable {
    private let lineStarts: [Int]
    let utf8Count: Int

    init(source: String) {
        let bytes = Array(source.utf8)
        var starts = [0]
        for index in bytes.indices where bytes[index] == 0x0A {
            starts.append(index + 1)
        }
        lineStarts = starts
        utf8Count = bytes.count
    }

    func offset(line: Int, utf8Column: Int) -> Int? {
        guard line > 0, utf8Column > 0, line <= lineStarts.count else { return nil }
        let value = lineStarts[line - 1] + utf8Column - 1
        let lineEnd = line < lineStarts.count ? lineStarts[line] : utf8Count
        guard value >= lineStarts[line - 1], value <= lineEnd else { return nil }
        return value
    }

    func range(
        startLine: Int,
        startUTF8Column: Int,
        endLine: Int,
        endUTF8Column: Int
    ) -> MarkdownSourceRange? {
        guard let lowerBound = offset(line: startLine, utf8Column: startUTF8Column),
              let upperBound = offset(line: endLine, utf8Column: endUTF8Column) else {
            return nil
        }
        do {
            return try MarkdownSourceRange(lowerBound: lowerBound, upperBound: upperBound)
        } catch {
            DebugLog.reader("Invalid Swift Markdown source range: \(error)")
            return nil
        }
    }
}

/// Immutable reader-owned preparation result. Swift Markdown remains the only
/// standard Markdown AST; wiki syntax is a source-ranged overlay on the same
/// normalized source bytes.
/// The Swift Markdown `Document` has no `Sendable` conformance. This wrapper
/// exposes only immutable state, and the render task never mutates the AST.
// swiftlint:disable:next unchecked_sendable
struct PreparedMarkdownDocument: @unchecked Sendable {
    let sourceMarkdown: String
    var normalizedMarkdown: String { sourceMarkdown }
    let document: Document
    let wikiSyntax: [WikiMarkdownSyntaxNode]
    let lineTable: MarkdownSourceLineTable
    let documentIdentity: MarkdownDocumentIdentity?
    let contentKind: ReaderMarkdown.ContentKind

    init(
        sourceMarkdown: String,
        documentIdentity: MarkdownDocumentIdentity?,
        contentKind: ReaderMarkdown.ContentKind
    ) {
        self.sourceMarkdown = sourceMarkdown
        document = Document(parsing: sourceMarkdown)
        lineTable = MarkdownSourceLineTable(source: sourceMarkdown)
        self.documentIdentity = documentIdentity
        self.contentKind = contentKind

        let parsed = WikiLinkParser.syntaxNodes(in: sourceMarkdown)
        if Self.hasValidOverlay(parsed, utf8Count: sourceMarkdown.utf8.count) {
            wikiSyntax = parsed
        } else {
            DebugLog.reader("Wiki syntax overlay validation failed; rendering authored Markdown without typed wiki nodes")
            wikiSyntax = []
        }
    }

    private static func hasValidOverlay(_ nodes: [WikiMarkdownSyntaxNode], utf8Count: Int) -> Bool {
        var cursor = 0
        for node in nodes {
            let range = node.sourceRange
            guard range.lowerBound >= cursor,
                  range.upperBound <= utf8Count else {
                return false
            }
            cursor = range.upperBound
        }
        return true
    }
}

/// Prepare normalized Markdown and its typed wiki syntax overlay.
enum ReaderMarkdown {
    /// The document class selects source-specific normalization while keeping
    /// chat and page Markdown verbatim.
    enum ContentKind: Hashable, Sendable {
        case document
        case source
    }

    static func preparedDocument(
        _ raw: String,
        contentKind: ContentKind = .document,
        documentIdentity: MarkdownDocumentIdentity? = nil
    ) -> PreparedMarkdownDocument {
        let markdown: String
        switch contentKind {
        case .document:
            markdown = raw
        case .source:
            markdown = SourceMarkdownFormat.stripped(body: raw)
        }
        return PreparedMarkdownDocument(
            sourceMarkdown: footnotePreparedMarkdown(markdown),
            documentIdentity: documentIdentity,
            contentKind: contentKind)
    }

    private static func footnotePreparedMarkdown(_ markdown: String) -> String {
        let rendered = WikiFootnoteMarkdown.rendered(markdown)
        guard !rendered.footnotes.isEmpty else { return rendered.bodyMarkdown }
        let footnotes: String = rendered.footnotes.map { footnote -> String in
            let anchor = "<a id=\"\(WikiFootnoteMarkdown.footnoteAnchorID(for: footnote.id))\"></a>"
            return "\(footnote.number). \(anchor)\(footnote.markdown)"
        }.joined(separator: "\n")
        return "\(rendered.bodyMarkdown)\n\n---\n\n\(footnotes)"
    }
}
