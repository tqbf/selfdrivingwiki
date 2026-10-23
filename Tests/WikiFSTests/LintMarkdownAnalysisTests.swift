import Foundation
import Testing
import Markdown
@testable import WikiFSCore
@testable import WikiFSMarkdown

/// AC.3 parser-parity contract: lint and the reader share the SAME parser
/// configuration and code protection, while every range stays an authored
/// UTF-8 byte location.
struct LintMarkdownAnalysisTests {

    /// The shared parse entry produces the same AST the reader builds —
    /// node-for-node over a document exercising fences, tables, lists,
    /// headings, inline code, and wiki links.
    @Test func rendererParity() {
        let source = """
        # Heading

        Intro with `inline code` and [[Some Page]].

        ```swift
        let x = "[[Not A Link]]"
        ```

        | A | B |
        |---|---|
        | 1 | 2 |

        - item one
        - item two
        """
        let parsed = ParsedMarkdownDocument(parsing: source)
        let readerDocument = Document(parsing: source)

        func shape(_ markup: Markup) -> [String] {
            var shapes: [String] = [String(describing: type(of: markup))]
            for child in markup.children {
                shapes.append(contentsOf: shape(child))
            }
            return shapes
        }
        #expect(shape(parsed.document) == shape(readerDocument))
    }

    /// AST-derived code protection covers tilde fences and indented code
    /// blocks — forms the legacy heuristic protector missed — while inline
    /// code spans stay protected as before.
    @Test func codeProtectionCoversAllASTForms() {
        let source = """
        Before `[[Not A Link]]` inline.

        ~~~
        [[Tilde Protected]]
        ~~~

        Normal paragraph.

            [[Indented Protected]]
        """
        let parsed = ParsedMarkdownDocument(parsing: source)
        let protection = parsed.codeProtection

        let tildeRange = range(of: "[[Tilde Protected]]", in: source)
        let indentedRange = range(of: "[[Indented Protected]]", in: source)
        let inlineRange = range(of: "[[Not A Link]]", in: source)
        #expect(protection.protects(tildeRange), "tilde fences must be protected (old heuristic missed them)")
        #expect(protection.protects(indentedRange), "indented code blocks must be protected (old heuristic missed them)")
        #expect(protection.protects(inlineRange))
        // A plain paragraph wiki link is never protected.
        let plain = "plain [[Open Page]] text"
        #expect(!protectionOn(plain).protects(range(of: "[[Open Page]]", in: plain)))
    }

    private func protectionOn(_ source: String) -> MarkdownCodeProtection {
        ParsedMarkdownDocument(parsing: source).codeProtection
    }

    /// Fence facts preserve marker, length, container context, opening
    /// range, and observed closing range — including tilde fences,
    /// variable-length closers, blockquote containers, and legal EOF fences.
    @Test func fenceFactsCaptureDelimiterDetails() {
        let source = """
        Prose.

        ~~~~ tilde-info
        content
        ~~ short line is content
        ~~~~
        > ```mermaid
        > flowchart LR
        > ```
        Left open:

        ```text
        never closed
        """
        let parsed = ParsedMarkdownDocument(parsing: source)
        let facts = parsed.fenceFacts

        #expect(facts.count == 3)
        // Tilde fence with a four-marker opener; the shorter `~~` line is
        // CONTENT (CommonMark: closer must be >= opener length).
        let tilde = facts[0]
        #expect(tilde.marker == .tilde)
        #expect(tilde.length == 4)
        #expect(tilde.infoString == "tilde-info")
        #expect(tilde.closingRange != nil)
        #expect(slice(source, tilde.closingRange!) == "~~~~")
        #expect(slice(source, tilde.openingRange) == "~~~~")

        // Blockquote container: the fence opens inside `> ` and closes with
        // the same container prefix.
        let quoted = facts[1]
        #expect(quoted.marker == .backtick)
        #expect(quoted.containerPrefix == "> ")
        #expect(quoted.infoString == "mermaid")
        #expect(quoted.closingRange != nil)
        #expect(slice(source, quoted.closingRange!) == "```")

        // EOF-closed fence: legal, and reported as such.
        let eof = facts[2]
        #expect(eof.isClosedAtEndOfFile)
        #expect(eof.closingRange == nil)
    }

    /// Authored byte locations survive CRLF line endings and multi-byte
    /// Unicode: ranges index the authored UTF-8 bytes, and slices decode
    /// exactly the bytes they span.
    @Test func utf8AndCRLFLocations() {
        let source = "Héllo wörld ✓.\r\n\r\n```swift\r\nlet a = 1\r\n```\r\n\r\nSee [[Café Page]]."
        let parsed = ParsedMarkdownDocument(parsing: source)

        // The fence spans exactly the delimiter bytes even across CRLFs.
        let facts = parsed.fenceFacts
        #expect(facts.count == 1)
        #expect(facts[0].marker == .backtick)
        #expect(facts[0].closingRange != nil)

        // A slice of the body text decodes to the authored characters.
        let linkRange = range(of: "[[Café Page]]", in: source)
        let decoded = LintPagePreflight.slice(source, linkRange)
        #expect(decoded == "[[Café Page]]")

        // Code protection still distinguishes the fenced bytes.
        #expect(parsed.codeProtection.protects(range(of: "let a = 1", in: source)))
        #expect(!parsed.codeProtection.protects(linkRange))
    }

    // MARK: - Helpers

    private func range(of needle: String, in source: String) -> MarkdownSourceRange {
        let stringRange = source.range(of: needle)!
        let lower = source.utf8.distance(from: source.utf8.startIndex, to: stringRange.lowerBound.samePosition(in: source.utf8)!)
        let upper = source.utf8.distance(from: source.utf8.startIndex, to: stringRange.upperBound.samePosition(in: source.utf8)!)
        // swiftlint:disable:next silent_try_optional
        return (try? MarkdownSourceRange(lowerBound: lower, upperBound: upper))!
    }

    private func slice(_ source: String, _ range: MarkdownSourceRange) -> String {
        LintPagePreflight.slice(source, range)
    }
}

/// AC.3 footnote-analysis contract: occurrences are preserved with authored
/// locations; duplicates are kept; literal examples in code stay untouched.
struct LintFootnoteAnalysisTests {

    private func analyze(_ source: String) -> MarkdownFootnoteAnalysis {
        let parsed = ParsedMarkdownDocument(parsing: source)
        return MarkdownFootnoteAnalysis.analyze(
            in: source,
            protectedRanges: WikiFootnoteMarkdown.utf16Ranges(of: parsed.codeProtection, in: source))
    }

    /// Duplicate definitions survive with BOTH ranges; undefined references
    /// and orphan definitions are identified separately.
    @Test func duplicatesAndLiteralExamples() {
        let source = """
        Body [^one] and [^two].

        [^one]: First [[source:Smith2023#"quote one"]]
        [^one]: Second definition — the old dictionary dropped this
        [^two]: Two's definition
        [^orphan]: never referenced

        Literal example:

        ```
        [^fake]: this is inside a fence, not a definition
        and [^fake] is not a reference
        ```
        """
        let analysis = analyze(source)

        // Duplicates preserved with authored locations.
        #expect(analysis.definitions.filter { $0.id == "one" }.count == 2)
        #expect(analysis.duplicateDefinitionIDs == ["one"])

        // `[^two]` referenced and defined; `[^orphan]` defined never referenced;
        // `[^fake]` is literal code — neither a definition nor a reference.
        #expect(analysis.undefinedReferenceIDs.isEmpty)
        #expect(analysis.orphanDefinitionIDs == ["orphan"])
        #expect(analysis.references.map(\.id) == ["one", "two"])
        #expect(analysis.definitions.map(\.id) == ["one", "one", "two", "orphan"])

        // Ranges point at the authored bytes of each occurrence.
        let secondDefinition = analysis.definitions[1]
        #expect(source.contains("Second definition"))
        let slice = LintPagePreflight.slice(source, secondDefinition.utf8Range)
        #expect(slice.hasPrefix("[^one]: Second definition"))
    }

    /// The reader's rendering path stays compatible: the same input renders
    /// the same footnotes through the refactored path as the old dictionary
    /// produced for non-duplicate inputs.
    @Test func readerRenderCompatible() {
        let source = """
        Alpha claim.[^a] Beta claim.[^b]

        [^b]: Beta [[source:Beta2023#"beta quote"]]
        [^a]: Alpha [[source:Alpha2023#"alpha quote"]]
        """
        let rendered = WikiFootnoteMarkdown.rendered(source)
        #expect(rendered.footnotes.map(\.id) == ["a", "b"])
        #expect(rendered.footnotes[0].markdown.contains("Alpha2023"))
        #expect(rendered.footnotes[1].markdown.contains("Beta2023"))
        // The body keeps the prose, definitions removed, references numbered.
        #expect(rendered.bodyMarkdown.contains("Alpha claim."))
        #expect(!rendered.bodyMarkdown.contains("[^a]:"))
        #expect(rendered.bodyMarkdown.contains("¹"))
        // A document with no footnotes renders unchanged.
        let plain = "No footnotes here."
        #expect(WikiFootnoteMarkdown.rendered(plain).bodyMarkdown == plain)
    }
}
