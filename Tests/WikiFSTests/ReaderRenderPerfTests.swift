import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// Headless benchmark for the WKWebView reader render path: isolates the
/// non-layout costs the reader runs off the main actor — preprocessing
/// (footnote expansion + wiki-link linkification) and the swift-markdown → HTML
/// render (`MarkdownHTMLRenderer`) — on a ~512 KB synthetic source. This is the
/// path `WikiReaderView`'s detached convert task runs before handing HTML to
/// `WKWebView`.
///
/// Layout (WebKit painting the windowed document) can't be timed headlessly and
/// is the remaining unknown — capture it in Instruments against the
/// `reader.preprocess` / `webview.convert` signposts (`com.selfdrivingwiki.debug`).
///
/// (This superseded a Textual-era benchmark that also measured the native
/// reader's Markdown→`AttributedString` parse; that reader — and its parse axis —
/// was removed in `plans/textual-to-wkwebview.md`.)
///
/// Run just this benchmark with:
///
///   swift test --filter ReaderRenderPerfTests
struct ReaderRenderPerfTests {

    private static let targetBytes = 512 * 1024

    @Test func preprocessVsWebRenderSplitOnLargeSource() {
        let raw = Self.makeLargeMarkdown(targetBytes: Self.targetBytes)
        let bytes = raw.utf8.count

        // Faithfully replay `ReaderMarkdown.prepared` (string cost only — the
        // `isResolved` closure is a constant, so no per-link DB lookup; that
        // lookup is a separate axis measured against a real store).
        func preprocess(_ source: String) -> String {
            let rendered = WikiFootnoteMarkdown.rendered(source)
            let body = WikiLinkMarkdown.linkified(rendered.bodyMarkdown)
            guard !rendered.footnotes.isEmpty else { return body }
            let footnotes = rendered.footnotes
                .map { "\($0.number). \(WikiLinkMarkdown.linkified($0.markdown))" }
                .joined(separator: "\n")
            return "\(body)\n\n---\n\n\(footnotes)"
        }

        // Warm up (regex caches, swift-markdown) before timing.
        _ = MarkdownHTMLRenderer.render(preprocess(raw))

        // Preprocess: median of 5 runs (median ignores GC/scheduling spikes).
        var preprocessSamples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = preprocess(raw)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            preprocessSamples.append(Double(elapsedNs) / 1_000_000)
        }
        preprocessSamples.sort()
        let preprocessMs = preprocessSamples[preprocessSamples.count / 2]

        // Web render: the swift-markdown → HTML render the reader runs off-main,
        // on the fully preprocessed string (what `WikiReaderView` converts).
        let rendered = preprocess(raw)
        var convertSamples: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = MarkdownHTMLRenderer.render(rendered)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            convertSamples.append(Double(elapsedNs) / 1_000_000)
        }
        convertSamples.sort()
        let convertMs = convertSamples[convertSamples.count / 2]

        // Sanity: the full pipeline produced a non-empty document.
        let html = MarkdownHTMLRenderer.render(rendered)
        #expect(html.isEmpty == false)

        let kb = Double(bytes) / 1024.0
        print("""

        ── reader render-path benchmark (WKWebView) ─────────────
        source size : \(bytes) bytes (\(String(format: "%.0f", kb)) KB)
        preprocess  : \(String(format: "%.1f", preprocessMs)) ms  (footnote expand + wiki-link linkify, full string)
        web render  : \(String(format: "%.1f", convertMs)) ms  (swift-markdown → HTML)
        ──────────────────────────────────────────────────────────
        """)
    }

    // MARK: - Helpers

    /// Deterministic markdown shaped like a pdf2md extraction: headings,
    /// paragraphs with inline `[[wiki links]]`, and footnote refs + definitions.
    /// Footnote labels are globally unique so `WikiFootnoteMarkdown.rendered`
    /// renumbering is unambiguous across the whole document.
    private static func makeLargeMarkdown(targetBytes: Int) -> String {
        var output = ""
        var section = 0
        while output.utf8.count < targetBytes {
            section += 1
            output += "# Section \(section) — Overview\n\n"
            for p in 0..<4 {
                output += "This is paragraph \(p) of section \(section). "
                output += "It references [[Page \(p)]] and [[source:Paper \(section)]] inline, "
                output += "and cites a result[^f-\(section)-\(p)]. "
                output += String(repeating: "Filler prose to pad the block to a realistic length. ", count: 8)
                output += "\n\n"
            }
            for p in 0..<4 {
                output += "[^f-\(section)-\(p)]: Footnote definition \(p) for section \(section).\n"
            }
            output += "\n"
        }
        return output
    }
}
