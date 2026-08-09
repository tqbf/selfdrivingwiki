#if os(macOS)
import Testing
@testable import WikiFS

struct CodeSyntaxHighlighterSecurityTests {
    private static let paletteClasses: Set<String> = [
        "sdw-code-keyword", "sdw-code-string", "sdw-code-comment", "sdw-code-type",
        "sdw-code-function", "sdw-code-property", "sdw-code-number", "sdw-code-operator",
        "sdw-code-punctuation", "sdw-code-constant",
    ]

    @Test("AC.2 HTML and script payloads remain inert and text equivalent")
    func testHTMLAndScriptPayloadsRemainInertAndTextEquivalent() {
        let source = #"<script data-value="&<>">alert("<&>")</script>"#
        guard let html = CodeSyntaxHighlighter.highlightedHTML(
            source: source,
            language: .html,
            isCancelled: { false })
        else {
            Issue.record("Expected highlighted HTML")
            return
        }

        #expect(html.contains("<script") == false)
        #expect(html.contains("&lt;") == true)
        #expect(Self.textContent(of: html) == source)
    }

    @Test("AC.2 capture names cannot inject attributes or classes")
    func testCaptureNamesCannotInjectAttributesOrClasses() {
        let adversarialCaptureName = #"keyword\"><img src=x onerror=alert(1)>"#
        let source = "let captureName = \"\(adversarialCaptureName)\""
        guard let html = CodeSyntaxHighlighter.highlightedHTML(
            source: source,
            language: .swift,
            isCancelled: { false })
        else {
            Issue.record("Expected highlighted Swift")
            return
        }

        #expect(html.contains("<img") == false)
        #expect(html.contains("onerror=") == true)
        #expect(Self.spanClasses(in: html).allSatisfy { Self.paletteClasses.contains($0) })
        #expect(Self.textContent(of: html) == source)
    }

    @Test("every closed palette class has a reader stylesheet rule")
    func testReaderStylesheetDefinesEveryClosedPaletteClass() {
        let document = WikiReaderView.documentHTML("")
        for paletteClass in Self.paletteClasses {
            #expect(document.contains(".\(paletteClass) { color: var(--"))
        }
    }

    private static func spanClasses(in html: String) -> [String] {
        html.components(separatedBy: "<span class=\"")
            .dropFirst()
            .compactMap { $0.split(separator: "\"", maxSplits: 1).first.map(String.init) }
    }

    private static func textContent(of html: String) -> String {
        var result = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">" where insideTag: insideTag = false
            case _ where insideTag == false: result.append(character)
            default: break
            }
        }
        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
#endif
