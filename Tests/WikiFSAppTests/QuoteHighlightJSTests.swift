#if os(macOS)
import Testing
@testable import WikiFS
@testable import WikiFSEngine

/// Tests for `WikiReaderRep.highlightJS(quote:)` — the pure function that emits
/// the JavaScript the WKWebView reader runs to highlight + scroll to a quoted
/// passage. This replaces the retired `WikiLinkStylingParser.quoteRange` Swift
/// tests (17): the logic now lives in JS (`window.find` + a whitespace-tolerant
/// TreeWalker fallback), and these assert against the **emitted JS string
/// output** — guarding the escaping and the match/fallback logic — without a
/// JSContext. (Live `<mark>` placement in a rendered WKWebView is a manual gate.)
struct QuoteHighlightJSTests {

    @Test func embedsTheQuote() {
        let js = WikiReaderRep.highlightJS(quote: "hello")
        #expect(js.contains(#")("hello")"#))
    }

    @Test func searchesWholeDocumentAcrossNodes() {
        // The quote is searched across ALL text nodes (a quote can span an inline
        // link/bold), so the JS walks the whole body and wraps each intersecting
        // text segment — not a single-node `window.find` (unreliable) search.
        let js = WikiReaderRep.highlightJS(quote: "hello")
        #expect(!js.contains("window.find"))
        #expect(js.contains("createTreeWalker"))
        #expect(js.contains("indexOf"))
        #expect(js.contains("intersectsNode"))
        #expect(js.contains("splitText"))
    }

    @Test func hasWhitespaceTolerantTreeWalkerFallback() {
        let js = WikiReaderRep.highlightJS(quote: "hello world")
        #expect(js.contains("createTreeWalker"))
        // Whitespace is collapsed (not left as raw \s+) before comparing, so a
        // quote with extra spaces still matches a collapsed haystack.
        #expect(js.contains("replace(/\\s+/g"))
        #expect(js.contains("toLowerCase"))
    }

    @Test func wrapsMatchInSdwhlMark() {
        let js = WikiReaderRep.highlightJS(quote: "hello")
        #expect(js.contains("mark"))
        #expect(js.contains("sdwhl"))
        #expect(js.contains("scrollIntoView"))
    }

    @Test func wrapsMatchedRangeAcrossNodes() {
        // The match becomes a Range (start/end nodes from the index map) wrapped
        // per text segment via splitText, so a quote spanning an inline element
        // still highlights. This is what makes highlight actually appear.
        let js = WikiReaderRep.highlightJS(quote: "the results")
        #expect(js.contains("setStart"))
        #expect(js.contains("setEnd"))
        #expect(js.contains("nodeValue"))
        #expect(js.contains("splitText"))
        // The map maps normalized positions back to (node, char offset).
        #expect(js.contains("map[s].n"))
        #expect(js.contains("map[e].n"))
    }

    @Test func escapesDoubleQuotesInEmbeddedQuote() {
        // A quote containing a double quote must be backslash-escaped so it
        // can't terminate the JS string literal early.
        let js = WikiReaderRep.highlightJS(quote: #"he said "hi""#)
        #expect(js.contains(#"\"hi\""#))
        // And must NOT contain the unescaped form that would break the literal.
        #expect(!js.contains(#")("he said "hi"")"#))
    }

    @Test func escapesBackslashes() {
        let js = WikiReaderRep.highlightJS(quote: #"a\b"#)
        #expect(js.contains(#"a\\b"#))
    }

    @Test func escapesNewlines() {
        // An actual newline in the quote becomes the two-char \n escape.
        let js = WikiReaderRep.highlightJS(quote: "a\nb")
        #expect(js.contains(#"a\nb"#))
    }

    // MARK: - jsString helper (the escaping primitive)

    @Test func jsStringEscapesQuote() {
        #expect(WikiReaderRep.jsString(#"a"b"#) == #"a\"b"#)
    }

    @Test func jsStringEscapesBackslash() {
        #expect(WikiReaderRep.jsString(#"a\b"#) == #"a\\b"#)
    }

    @Test func jsStringEscapesNewline() {
        #expect(WikiReaderRep.jsString("a\nb") == #"a\nb"#)
    }

    @Test func jsStringEscapesCarriageReturn() {
        #expect(WikiReaderRep.jsString("a\rb") == #"a\rb"#)
    }
}
#endif
