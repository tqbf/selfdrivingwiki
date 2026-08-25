#if os(macOS)
import Markdown
import Testing
import WikiFSCore
@testable import WikiFS

struct MarkdownRangeProbeTests {
    @Test func reportsParsedRanges() {
        let document = Document(parsing: "**before** [[Page|label]] *after* π")
        let nodes = Array(document.children)
        #expect(nodes.count == 1)
        let paragraph = nodes[0]
        #expect(paragraph.range != nil)
        let children = Array(paragraph.children)
        #expect(children.allSatisfy { $0.range != nil })
        let prepared = ReaderMarkdown.preparedDocument("**before** [[Page|label]] *after* π")
        let overlay = try! #require(prepared.wikiSyntax.first).sourceRange
        let childRanges = children.compactMap { child -> MarkdownSourceRange? in
            guard let range = child.range else { return nil }
            return prepared.lineTable.range(
                startLine: range.lowerBound.line,
                startUTF8Column: range.lowerBound.column,
                endLine: range.upperBound.line,
                endUTF8Column: range.upperBound.column)
        }
        #expect(childRanges.contains { $0.contains(overlay) || overlay.contains($0) })
    }
}
#endif
