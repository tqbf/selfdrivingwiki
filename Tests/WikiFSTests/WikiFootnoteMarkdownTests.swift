import Foundation
import Testing
@testable import WikiFSCore

struct WikiFootnoteMarkdownTests {

    @Test func extractsDefinitionAndNumbersReference() {
        let rendered = WikiFootnoteMarkdown.rendered("""
        A sentence with a note[^source].

        [^source]: Footnote **markdown**.
        """)

        #expect(rendered.bodyMarkdown == "A sentence with a note[¹](wiki-footnote://note?id=source).\n")
        #expect(rendered.footnotes == [
            WikiFootnoteMarkdown.Footnote(id: "source", number: 1, markdown: "Footnote **markdown**.")
        ])
    }

    @Test func ordersFootnotesByFirstReferenceNotDefinitionOrder() {
        let rendered = WikiFootnoteMarkdown.rendered("""
        First[^b], then[^a], then repeat[^b].

        [^a]: Alpha
        [^b]: Beta
        """)

        #expect(rendered.bodyMarkdown.contains("First[¹](wiki-footnote://note?id=b)"))
        #expect(rendered.bodyMarkdown.contains("then[²](wiki-footnote://note?id=a)"))
        #expect(rendered.bodyMarkdown.contains("repeat[¹](wiki-footnote://note?id=b)"))
        #expect(rendered.footnotes.map(\.id) == ["b", "a"])
    }

    @Test func leavesUnknownReferencesLiteral() {
        let rendered = WikiFootnoteMarkdown.rendered("Missing[^nope].")
        #expect(rendered.bodyMarkdown == "Missing[^nope].")
        #expect(rendered.footnotes.isEmpty)
    }

    @Test func supportsIndentedContinuationLines() {
        let rendered = WikiFootnoteMarkdown.rendered("""
        See[^long].

        [^long]: First line.
            Continued with [[Wiki Link]].
        """)

        #expect(rendered.footnotes.first?.markdown == "First line.\nContinued with [[Wiki Link]].")
    }

    @Test func codeSpansAndFencesStayLiteral() {
        let rendered = WikiFootnoteMarkdown.rendered("""
        Literal `[^x]`, real[^real].

        ```
        [^x]: Not a definition.
        ```

        [^real]: Render me.
        """)

        #expect(rendered.bodyMarkdown.contains("Literal `[^x]`, real[¹](wiki-footnote://note?id=real)."))
        #expect(rendered.bodyMarkdown.contains("[^x]: Not a definition."))
        #expect(rendered.footnotes.map(\.id) == ["real"])
    }

    @Test func doubleDigitReferencesRenderAsSuperscriptMarkers() {
        let definitions = (1...10)
            .map { "[^n\($0)]: Note \($0)" }
            .joined(separator: "\n")
        let references = (1...10)
            .map { "ref[^n\($0)]" }
            .joined(separator: " ")
        let rendered = WikiFootnoteMarkdown.rendered("\(references)\n\n\(definitions)")

        #expect(rendered.bodyMarkdown.contains("ref[¹⁰](wiki-footnote://note?id=n10)"))
        #expect(rendered.footnotes.last?.number == 10)
    }
}
