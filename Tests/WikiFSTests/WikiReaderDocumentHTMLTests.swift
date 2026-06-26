import Testing
@testable import WikiFS

/// Tests for the `mermaidScript` parameter added to `WikiReaderView.documentHTML`.
///
/// `documentHTML` is `nonisolated static` and pure — these tests verify its
/// injection behaviour off the main actor. The mermaid runtime itself is not
/// injected during `swift test` (the bundle resource is absent), so we pass a
/// short sentinel string to exercise the injection paths without needing the
/// real ~2.5 MB file.
struct WikiReaderDocumentHTMLTests {

    /// A small body that represents a page containing a mermaid diagram block.
    let body = #"<pre class="mermaid">graph TD</pre>"#

    // MARK: - Script injection with a non-empty script

    @Test func withNonEmptyMermaidScriptInjectsTwoScriptTags() {
        let html = WikiReaderView.documentHTML(body, mermaidScript: "MERMAID_RUNTIME")

        // Runtime sentinel must appear in the output.
        #expect(html.contains("MERMAID_RUNTIME"))

        // Init script must configure strict security (mermaid's safe default;
        // 'loose' is a historical XSS vector).
        #expect(html.contains("securityLevel: 'strict'"))

        // Init script must call mermaid.run() to render the diagrams.
        #expect(html.contains("mermaid.run()"))

        // Theme is picked from prefers-color-scheme at init (a key plan decision).
        #expect(html.contains("prefers-color-scheme"))

        // startOnLoad must be false — we drive rendering explicitly via run().
        #expect(html.contains("startOnLoad: false"))

        // Exactly two <script blocks: one runtime, one init.
        let count = html.components(separatedBy: "<script").count - 1
        #expect(count == 2)

        // The runtime <script> MUST precede the init script — otherwise `mermaid`
        // is undefined when initialize() runs. This is the load-order invariant
        // the implementation comment calls out; pin it so a reorder can't pass.
        let runtimeIdx = html.range(of: "MERMAID_RUNTIME")?.lowerBound
        let initIdx = html.range(of: "mermaid.initialize")?.lowerBound
        #expect(runtimeIdx != nil && initIdx != nil)
        if let runtimeIdx, let initIdx {
            #expect(runtimeIdx < initIdx, "runtime <script> must precede the init script")
        }
    }

    // MARK: - No injection when script is nil

    @Test func withNilMermaidScriptInjectsNoScriptTags() {
        // Default (nil) — no mermaid param passed.
        let html = WikiReaderView.documentHTML(body)
        let count = html.components(separatedBy: "<script").count - 1
        #expect(count == 0, "non-diagram pages must inject zero <script> tags")
    }

    // MARK: - Empty string treated as nil

    @Test func withEmptyMermaidScriptInjectsNoScriptTags() {
        // Empty string arises when MermaidAsset.js returns "" outside the app
        // bundle (dev / swift test). documentHTML must treat it identically to nil.
        let html = WikiReaderView.documentHTML(body, mermaidScript: "")
        let count = html.components(separatedBy: "<script").count - 1
        #expect(count == 0, "empty mermaid script must be treated as nil — no injection")
    }

    // MARK: - Body wrapping is intact in all cases

    @Test func bodyAppearsInsideArticleInAllCases() {
        let cases: [String?] = [nil, "", "MERMAID_RUNTIME"]
        for script in cases {
            let html = WikiReaderView.documentHTML(body, mermaidScript: script)
            #expect(
                html.contains("<article>\(body)</article>"),
                "body must be wrapped in <article> regardless of mermaidScript=\(String(describing: script))"
            )
        }
    }
}
