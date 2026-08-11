#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WikiFS
@testable import WikiFSCodeHighlighting

struct CodeSyntaxHighlighterTests {
    @Test("all approved languages produce escaped allowlisted spans")
    func testJavaScalaHTMLSwiftJSONProduceAllowlistedTokenSpans() {
        let samples: [(CodeLanguage, String)] = [
            (.java, "class Example { int value = 1; }"),
            (.scala, "object Example { val value = 1 }"),
            (.html, "<script>value</script>"),
            (.swift, "let value = 1"),
            (.json, "{\"value\": 1}"),
        ]
        for (language, source) in samples {
            guard let html = CodeSyntaxHighlighter.highlightedHTML(source: source, language: language, isCancelled: { false }) else {
                Issue.record("Expected result for \(language)")
                continue
            }
            #expect(html.contains("sdw-code-"))
            #expect(!html.contains("<script>"))
            #expect(!html.contains("class=\"keyword\""))
        }
    }

    @Test("unknown, oversized, and cancelled input return plain-code fallback signal")
    func testUnknownAndOversizedLanguagesReturnEscapedPlainCode() {
        #expect(CodeLanguage.fromFenceInfo("javascript") == nil)
        #expect(CodeLanguage.fromFenceInfo("   ") == nil)
        let oversized = String(repeating: "x", count: CodeHighlightingPolicy.maximumHighlightedSourceBytes + 1)
        #expect(CodeSyntaxHighlighter.highlightedHTML(source: oversized, language: .swift, isCancelled: { false }) == nil)
        #expect(CodeSyntaxHighlighter.highlightedHTML(source: "let value = 1", language: .swift, isCancelled: { true }) == nil)
    }

    @Test("hostile HTML and multibyte source stay inert with exact text content")
    func testHostileHTMLAndMultibyteSourceStayInertAndTextEquivalent() {
        let source = #"<script data-value="&<>">alert("<&>")</script> café 😀"#
        guard let html = CodeSyntaxHighlighter.highlightedHTML(
            source: source,
            language: .html,
            isCancelled: { false })
        else {
            Issue.record("Expected highlighted HTML")
            return
        }

        #expect(!html.contains("<script"))
        #expect(html.contains("&lt;"))
        #expect(html.contains("script"))
        #expect(highlightedTextContent(html) == source)
    }

    @Test("concurrent calls keep parser state invocation-local")
    func testConcurrentHighlightCallsAreThreadConfined() async {
        let invocations = (0..<32).map { index in
            let language = CodeLanguage.allCases[index % CodeLanguage.allCases.count]
            return Invocation(language: language, source: Self.source(for: language, index: index))
        }
        let expected = invocations.map {
            CodeSyntaxHighlighter.highlightedHTML(source: $0.source, language: $0.language, isCancelled: { false })
        }
        let results = await withTaskGroup(of: (Int, String?).self, returning: [String?].self) { group in
            for (index, invocation) in invocations.enumerated() {
                group.addTask {
                    (index, CodeSyntaxHighlighter.highlightedHTML(
                        source: invocation.source,
                        language: invocation.language,
                        isCancelled: { false }))
                }
            }
            var values = Array<String?>(repeating: nil, count: invocations.count)
            for await (index, value) in group {
                values[index] = value
            }
            return values
        }
        #expect(expected.allSatisfy { $0 != nil })
        #expect(results == expected)
    }

    @Test("cancellation is checked before every ordinary fence")
    func testCancellationFallsBackBetweenBlocks() {
        let fences = Array(repeating: "~~~swift\nlet value = 1\n~~~", count: 2).joined(separator: "\n\n")
        let calls = Mutex(0)
        let html = MarkdownHTMLRenderer.render(fences, options: .reader, isCancelled: {
            calls.withLock {
                $0 += 1
                return $0 > 2
            }
        })
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains("let value = 1"))
        #expect(calls.withLock { $0 } >= 3)
    }

    private func highlightedTextContent(_ html: String) -> String {
        var result = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">" where insideTag: insideTag = false
            case _ where !insideTag: result.append(character)
            default: break
            }
        }
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private struct Invocation: Sendable {
        let language: CodeLanguage
        let source: String
    }

    private static func source(for language: CodeLanguage, index: Int) -> String {
        switch language {
        case .java: "class Example\(index) { int value = \(index); }"
        case .scala: "object Example\(index) { val value = \(index) }"
        case .html: "<example data-value=\"\(index)\">\(index)</example>"
        case .swift: "let value\(index) = \(index)"
        case .json: "{\"value\": \(index)}"
        }
    }
}

struct TreeSitterProvenanceTests {
    @Test("pinned runtime, grammar query, and license files are shipped")
    func testPinnedRuntimeGrammarQueriesAndLicenses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let required = [
            "Sources/CTreeSitterHighlighting/Runtime/lib.c",
            "Sources/CTreeSitterHighlighting/Grammar/Java/parser.c",
            "Sources/CTreeSitterHighlighting/Grammar/Scala/scanner.c",
            "Sources/CTreeSitterHighlighting/Grammar/HTML/tag.h",
            "Sources/CTreeSitterHighlighting/Grammar/Swift/scanner.c",
            "Sources/CTreeSitterHighlighting/Queries/swift-highlights.scm",
            "Sources/CTreeSitterHighlighting/Licenses/tree-sitter-runtime-MIT.txt",
            "plans/markdown-renderer-code-highlighting.md",
        ]
        for path in required {
            #expect(FileManager.default.fileExists(atPath: root.appending(path: path).path), "Missing \(path)")
        }
    }
}
#endif
