#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WikiFS

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
        let source = "let value = 1"
        let expected = CodeSyntaxHighlighter.highlightedHTML(source: source, language: .swift, isCancelled: { false })
        let results = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<32 {
                group.addTask {
                    CodeSyntaxHighlighter.highlightedHTML(source: source, language: .swift, isCancelled: { false })
                }
            }
            var values: [String?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        #expect(expected != nil)
        #expect(results.allSatisfy { $0 == expected })
    }

    @Test("cancellation is checked before every ordinary fence")
    func testCancellationFallsBackBetweenBlocks() {
        let fences = Array(repeating: "~~~swift\nlet value = 1\n~~~", count: 2).joined(separator: "\n\n")
        let calls = Mutex(0)
        let html = MarkdownHTMLRenderer.render(fences, isCancelled: {
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
