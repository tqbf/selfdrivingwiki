import Foundation
import Testing
import WebKit
import WikiFSCore
import WikiFSLinks
import WikiFSTypes
@testable import WikiFS

/// Plan v2 transclusion tests: linkify dispatch, pure fetch+render, and the
/// Coordinator handler's cycle-marker / safe-injection paths. See
/// `plans/page-embed-v2.md` §12.
@MainActor
struct TransclusionEmbedTests {

    // MARK: - §12.1 Pure linkify dispatch (WikiLinkMarkdown.linkified)

    @Test func pageEmbedEmitsDetailsBlock() {
        let out = WikiLinkMarkdown.linkified(
            "![[Home]]", isResolved: { _, _ in true })
        #expect(out.contains("<details class=\"sdw-transclusion\""))
        #expect(out.contains("data-sdw-embed-kind=\"page\""))
        #expect(out.contains("<summary>"))
        #expect(out.contains("Home"))
        #expect(!out.contains(" open"))           // collapsed-by-default
        #expect(!out.contains("wiki://page"))     // not a cite link
        #expect(!out.contains("!"))               // bang consumed
    }

    @Test func pageEmbedIsDistinctFromCiteLink() {
        let out = WikiLinkMarkdown.linkified(
            "[[Home]] and ![[Home]]", isResolved: { _, _ in true })
        #expect(out.contains("[Home](wiki://page?title=Home)"))  // cite link
        #expect(out.contains("sdw-transclusion"))                // embed
    }

    @Test func pageEmbedAliasBecomesSummaryHeader() {
        let out = WikiLinkMarkdown.linkified(
            "![[Cycle|the cycle]]", isResolved: { _, _ in true })
        #expect(out.contains("<span class=\"sdw-embed-title\">the cycle</span>"))
    }

    @Test func pageEmbedCanonicalULIDUsesCurrentName() {
        // 26-char Crockford base32 ULID (the form ULID.generate emits).
        let ulid = "01HTESTPG0000000000000000A"
        #expect(WikiLinkParser.isCanonicalULID(ulid))
        let out = WikiLinkMarkdown.linkified(
            "![[\(ulid)]]",
            isResolved: { _, _ in true },
            displayName: { id, kind in
                (id.rawValue == ulid && kind == .page) ? "Live Title" : nil
            })
        #expect(out.contains("data-sdw-embed-kind=\"page\""))
        #expect(out.contains("data-sdw-embed-id=\"\(ulid)\""))
        #expect(out.contains("<span class=\"sdw-embed-title\">Live Title</span>"))
    }

    @Test func nonMediaSourceEmbedEmitsDetails() {
        let id = PageID(rawValue: "01HTESTTXT00000000000000005")
        let out = WikiLinkMarkdown.linkified(
            "![[source:notes.txt]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "text/plain")
            })
        #expect(out.contains("data-sdw-embed-kind=\"source\""))
        #expect(out.contains("data-sdw-embed-id=\"\(id.rawValue)\""))
        #expect(!out.contains("<img"))
        #expect(!out.contains("<video"))
    }

    @Test func mediaSourceEmbedStillInline() {
        let id = PageID(rawValue: "01HTESTIMG0000000000000001")
        let out = WikiLinkMarkdown.linkified(
            "![[source:pic.png]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "image/png")
            })
        #expect(out.contains("<img"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
        #expect(!out.contains("sdw-transclusion"))
    }

    @Test func pdfSourceEmbedFollowsPolicy() {
        // Plan v2 §9: PDF is media — stays inline `<iframe>`.
        let id = PageID(rawValue: "01HTESTPDF0000000000000004")
        let out = WikiLinkMarkdown.linkified(
            "![[source:doc.pdf]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "application/pdf")
            })
        #expect(out.contains("<iframe"))
        #expect(out.contains("wiki-blob://source/\(id.rawValue)"))
        #expect(!out.contains("sdw-transclusion"))
    }

    @Test func mermaidSourceEmbedStillFenced() {
        let id = PageID(rawValue: "01HTESTMMD0000000000000007")
        let diagram = "graph TD\nA-->B"
        let target = EmbedTarget(kind: .diagram, url: id.rawValue, content: diagram)
        let out = WikiLinkMarkdown.linkified(
            "![[source:d.mmd]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "text/mermaid", target: target)
            })
        #expect(out.contains("```mermaid"))
        #expect(out.contains(diagram))
        #expect(!out.contains("sdw-transclusion"))
    }

    @Test func bareNameFallsBackToSource() {
        // `![[Foo]]` where no page "Foo" exists but a source does → source.
        let id = PageID(rawValue: "01HTESTSRC000000000000000F")
        let out = WikiLinkMarkdown.linkified(
            "![[Foo]]",
            isResolved: { name, kind in
                // Only the source namespace resolves "Foo".
                (name == "Foo" && kind == .source)
            },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "text/plain")
            })
        #expect(out.contains("data-sdw-embed-kind=\"source\""))
        #expect(out.contains("data-sdw-embed-id=\"\(id.rawValue)\""))
    }

    @Test func pageWinsOnCollision() {
        // Both page and source "Foo" resolve → page transclusion.
        let id = PageID(rawValue: "01HTESTPG0000000000000000B")
        let out = WikiLinkMarkdown.linkified(
            "![[Foo]]",
            isResolved: { _, _ in true },   // both namespaces resolve
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "text/plain")
            })
        #expect(out.contains("data-sdw-embed-kind=\"page\""))
        #expect(out.contains("data-sdw-embed-target=\"Foo\""))
    }

    @Test func explicitPagePrefixNeverSource() {
        // `![[page:Foo]]` with a source also named "Foo" → still page (no probe).
        let srcID = PageID(rawValue: "01HTESTPG0000000000000000C")
        let out = WikiLinkMarkdown.linkified(
            "![[page:Foo]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: srcID, mimeType: "text/plain")
            })
        #expect(out.contains("data-sdw-embed-kind=\"page\""))
        #expect(out.contains("data-sdw-embed-target=\"Foo\""))
    }

    @Test func explicitSourcePrefixAlwaysSource() {
        let id = PageID(rawValue: "01HTESTPG0000000000000000D")
        let out = WikiLinkMarkdown.linkified(
            "![[source:Foo]]",
            isResolved: { _, _ in true },
            embedInfo: { _ in
                WikiLinkMarkdown.SourceEmbedInfo(id: id, mimeType: "text/plain")
            })
        #expect(out.contains("data-sdw-embed-kind=\"source\""))
    }

    @Test func missingPageEmbedRendersBrokenHeader() {
        let out = WikiLinkMarkdown.linkified(
            "![[Ghost]]",
            isResolved: { _, _ in false })   // nothing resolves
        #expect(out.contains("sdw-transclusion"))
        #expect(out.contains("data-sdw-state=\"missing\""))
        #expect(out.contains("Page not found: Ghost"))
        #expect(!out.contains("data-sdw-embed-target"))  // no fetch metadata
    }

    @Test func missingSourceEmbedRendersBrokenHeader() {
        let out = WikiLinkMarkdown.linkified(
            "![[source:Ghost]]",
            isResolved: { _, _ in false },
            embedInfo: { _ in nil })
        #expect(out.contains("sdw-transclusion"))
        #expect(out.contains("data-sdw-state=\"missing\""))
        #expect(out.contains("Source not found: Ghost"))
        #expect(!out.contains("data-sdw-embed-target"))
    }

    @Test func pageEmbedInsideCodeSpanIsLiteral() {
        let out = WikiLinkMarkdown.linkified(
            "Use `![[Home]]` literally.", isResolved: { _, _ in true })
        #expect(out.contains("`![[Home]]`"))
        #expect(!out.contains("sdw-transclusion"))
    }

    @Test func escapedEmbedPrefixIsLiteral() {
        // `\![[Home]]` — the `\!` stays literal, the link is a normal cite link
        // (the `!` is NOT consumed for non-embeds). Regression for the
        // WikiLinkSpan.isEmbedPrefix escape guard.
        let out = WikiLinkMarkdown.linkified(
            "\\![[Home]]", isResolved: { _, _ in true })
        #expect(out.contains("wiki://page?title=Home"))
        #expect(!out.contains("sdw-transclusion"))
    }

    @Test func chatEmbedPrefixStillCiteLink() {
        // `![[chat:…]]` is invalid — falls through to a normal cite link
        // (the WikiLinkParser L184 reject gate stays in place for the graph).
        let out = WikiLinkMarkdown.linkified(
            "![[chat:Conv]]", isResolved: { _, _ in true })
        #expect(out.contains("wiki://chat?title=Conv"))
        #expect(!out.contains("sdw-transclusion"))
    }

    // MARK: - §12.2 Pure fetch+render (TransclusionEmbedder.renderEmbedBody)

    /// Build an in-memory store + a minimal hand-built WikiRenderContext that
    /// knows about its pages/sources. Keeps the test pure (no @MainActor model).
    private func contextFor(
        store: GRDBWikiStore,
        pages: [(id: String, title: String)],
        sources: [(id: String, name: String)] = []
    ) -> WikiRenderContext {
        let pageIDToName = Dictionary(uniqueKeysWithValues:
            pages.map { (PageID(rawValue: $0.id), $0.title) })
        let sourceIDToName = Dictionary(uniqueKeysWithValues:
            sources.map { (PageID(rawValue: $0.id), $0.name) })
        return WikiRenderContext(
            pageTitles: Set(pages.map { $0.title.lowercased() }),
            pageIDToName: pageIDToName,
            sourceNames: Set(sources.map { $0.name.lowercased() }),
            sourceIDToName: sourceIDToName,
            chatTitles: [],
            chatIDToName: [:],
            uniqueLooseKeys: [],
            embedMap: [:],
            sourceDerivedChain: [:],
            siblingMaps: [:],
            blobScheme: WikiLinkMarkdown.blobScheme)
    }

    @Test func renderEmbedBodyResolvesAndRenders() throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Inner")
        try store.updatePage(id: page.id, title: "Inner", body: "Hello **world**.")
        let context = contextFor(store: store, pages: [(page.id.rawValue, "Inner")])

        let html = try TransclusionEmbedder.renderEmbedBody(
            store: store, id: page.id, kind: .page, context: context)
        #expect(html.contains("Hello"))
        #expect(html.contains("<strong>world</strong>"))
        #expect(!TransclusionEmbedder.isEmpty(html))
    }

    @Test func renderEmbedBodyNestedEmbedsCollapse() throws {
        // A page whose body contains a `![[Inner]]` → rendered HTML has a
        // nested `<details class="sdw-transclusion">` with no `open` attribute.
        let store = try TestStoreFactory.inMemory()
        let inner = try store.createPage(title: "Inner")
        try store.updatePage(id: inner.id, title: "Inner", body: "inside")
        let outer = try store.createPage(title: "Outer")
        try store.updatePage(id: outer.id, title: "Outer",
                             body: "Outer body. ![[Inner]]")
        let context = contextFor(
            store: store,
            pages: [(inner.id.rawValue, "Inner"), (outer.id.rawValue, "Outer")])

        let html = try TransclusionEmbedder.renderEmbedBody(
            store: store, id: outer.id, kind: .page, context: context)
        #expect(html.contains("sdw-transclusion"))
        #expect(html.contains("data-sdw-embed-kind=\"page\""))
        // Collapsed-by-default: NO `open` attribute on the nested details.
        #expect(!html.contains("<details class=\"sdw-transclusion\" open"))
    }

    @Test func renderEmbedBodyMissingReturnsEmpty() throws {
        let store = try TestStoreFactory.inMemory()
        let ghostID = PageID(rawValue: "01HGHOST00000000000000000X")
        let context = contextFor(store: store, pages: [])

        // getPage throws → propagates as an error; the helper does NOT swallow
        // it (house rule). The Coordinator catches and renders "Failed to load".
        #expect(throws: Error.self) {
            _ = try TransclusionEmbedder.renderEmbedBody(
                store: store, id: ghostID, kind: .page, context: context)
        }
    }

    @Test func renderEmbedBodySourcePrefersHeadMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let pdf = Data("pdf".utf8)
        let src = try store.addSource(filename: "doc.pdf", data: pdf, mimeType: "application/pdf")
        _ = try store.appendProcessedMarkdown(
            sourceID: src.id, content: "# Extracted\n\nThe body.", origin: .extraction, note: nil)
        let context = contextFor(store: store, pages: [], sources: [(src.id.rawValue, "doc.pdf")])

        let html = try TransclusionEmbedder.renderEmbedBody(
            store: store, id: src.id, kind: .source, context: context)
        #expect(html.contains("Extracted"))
        #expect(html.contains("The body."))
    }

    @Test func renderEmbedBodySourceFallsBackToRawText() throws {
        let store = try TestStoreFactory.inMemory()
        let text = Data("Plain text body.".utf8)
        let src = try store.addSource(filename: "notes.txt", data: text, mimeType: "text/plain")
        // No extraction row → helper falls back to raw UTF-8 bytes.
        let context = contextFor(store: store, pages: [], sources: [(src.id.rawValue, "notes.txt")])

        let html = try TransclusionEmbedder.renderEmbedBody(
            store: store, id: src.id, kind: .source, context: context)
        #expect(html.contains("Plain text body."))
    }

    @Test func renderEmbedBodySourceNilForUnextractedBinary() throws {
        // Plan v2 §4.2 invariant: a binary source with no extraction →
        // sourceEmbedBody returns nil → renderEmbedBody returns the empty
        // sentinel. NO extraction is triggered (hard read-path rule).
        let store = try TestStoreFactory.inMemory()
        let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D])  // "%PDF-" header bytes
        let src = try store.addSource(filename: "doc.pdf", data: pdf, mimeType: "application/pdf")
        let context = contextFor(store: store, pages: [], sources: [(src.id.rawValue, "doc.pdf")])

        let body = try TransclusionEmbedder.sourceEmbedBody(store: store, id: src.id)
        #expect(body == nil)

        let html = try TransclusionEmbedder.renderEmbedBody(
            store: store, id: src.id, kind: .source, context: context)
        #expect(TransclusionEmbedder.isEmpty(html))
    }

    // MARK: - §12.2 Pure helpers (cycle + safe injection)

    @Test func cycleDetectionRecognizesAncestorId() {
        #expect(TransclusionEmbedder.isCycle(path: "A B C", id: "B"))
        #expect(TransclusionEmbedder.isCycle(path: "A B C", id: "C"))
        #expect(!TransclusionEmbedder.isCycle(path: "A B C", id: "D"))
        #expect(!TransclusionEmbedder.isCycle(path: "", id: "A"))
        #expect(!TransclusionEmbedder.isCycle(path: "A B", id: ""))
    }

    @Test func cycleMarkerHtmlIsMuted() {
        let html = TransclusionEmbedder.cycleMarkerHTML(name: "Foo")
        #expect(html.contains("sdw-embed-cycle"))
        #expect(html.contains("↩ Foo (cycle)"))
    }

    @Test func injectJSCallPassesHtmlAsParameter() {
        // Plan v2 §4.4 safe-injection mandate: the html MUST be a parameter to
        // sdwInjectEmbed (escaped via jsString), never concatenated into JS
        // source. Verify with the classic string-breakout payload `");...;//`
        // — jsString escapes every `"` as `\"`, so the parameter stays a
        // single string literal and the breakout fails.
        let nodeId = "embed-XYZ"
        let breakoutHTML = "<p>\");evil();//</p>"
        let js = TransclusionEmbedder.injectJSCall(nodeId: nodeId, html: breakoutHTML)

        // The call shape: `sdwInjectEmbed("nodeId", "escaped-html")`.
        #expect(js.hasPrefix("sdwInjectEmbed(\"embed-XYZ\", \""))
        #expect(js.hasSuffix("\")"))

        // Critical: every literal `"` inside the html MUST be escaped as `\"`
        // so JS parsing keeps it inside the string literal (no breakout).
        // Count un-escaped `"` in the JS source: exactly 4 (two parameter
        // boundaries on each side of nodeId and html).
        let withoutEscapedQuotes = js.replacingOccurrences(of: "\\\"", with: "")
        let unescapedQuoteCount = withoutEscapedQuotes.filter { $0 == "\"" }.count
        #expect(unescapedQuoteCount == 4)

        // The breakout payload survived as literal text inside the parameter
        // (this proves it didn't terminate the string early).
        #expect(js.contains("evil"))   // the literal text is intact...
        // ...but the `");` that would have terminated the string is preceded
        // by an escape — so JS sees it as literal characters, not a terminator.
        #expect(js.contains("\\\")"))
    }

    @Test func cycleMarkerJSCallReusesSafeInject() {
        let js = TransclusionEmbedder.cycleMarkerJSCall(nodeId: "n1", name: "Foo")
        #expect(js.hasPrefix("sdwInjectEmbed(\"n1\", \""))
        #expect(js.contains("sdw-embed-cycle"))
        #expect(js.contains("Foo"))
    }

    // MARK: - §12.3 Coordinator handler (Swift-level, recorder)

    /// Recorder for `deliverJS` — captures the JS source the handler would
    /// pass to `evaluateJavaScript`. Lets us assert the safe-injection mandate
    /// at the Swift level without driving a live WKWebView (live JS is NOT
    /// drivable in-process — Plan v2 §12.4 manual validation).
    private final class JSRecorder {
        var calls: [String] = []
        @MainActor
        func record(_ js: String) { calls.append(js) }
    }

    @Test func embedFetchHandlerSetsCycleMarker() async throws {
        let store = try TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        let coord = WikiReaderRep.Coordinator()
        coord.store = model
        let recorder = JSRecorder()
        coord.deliverJS = { [weak recorder] in recorder?.record($0) }

        // Simulate an embed whose ancestor path already contains the target
        // id "B" — the handler must render the cycle marker WITHOUT fetching.
        await coord.processEmbedFetch(body: [
            "nodeId": "n-cycle",
            "kind": "page",
            "id": "B",
            "target": "",
            "path": "A B",
            "name": "Page B",
        ])

        #expect(recorder.calls.count == 1)
        let js = try #require(recorder.calls.first)
        #expect(js.hasPrefix("sdwInjectEmbed(\"n-cycle\", \""))
        #expect(js.contains("sdw-embed-cycle"))
        #expect(js.contains("Page B"))
    }

    @Test func embedFetchHandlerCallsEvaluateJavaScriptWithEscapedPayload() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Foo")
        try store.updatePage(id: page.id, title: "Foo", body: "Foo body with `code`.")
        let model = WikiStoreModel(store: store)
        let coord = WikiReaderRep.Coordinator()
        coord.store = model
        let recorder = JSRecorder()
        coord.deliverJS = { [weak recorder] in recorder?.record($0) }

        // Simulate a canonical page embed expanding — the handler fetches the
        // body via the main-actor fallback (the in-memory store has no
        // readPool) and emits the safe-injection JS call.
        await coord.processEmbedFetch(body: [
            "nodeId": "n-page",
            "kind": "page",
            "id": page.id.rawValue,
            "target": "",
            "path": "",
            "name": "Foo",
        ])

        #expect(recorder.calls.count == 1)
        let js = try #require(recorder.calls.first)
        // The call shape: `sdwInjectEmbed("n-page", "<escaped html>")`.
        #expect(js.hasPrefix("sdwInjectEmbed(\"n-page\", \""))
        // The rendered body content made it through as a parameter (escaped).
        #expect(js.contains("Foo body"))
        // Safe-injection: no un-escaped `"` (every literal `"` is `\"`).
        let withoutEscapedQuotes = js.replacingOccurrences(of: "\\\"", with: "")
        let unescapedQuoteCount = withoutEscapedQuotes.filter { $0 == "\"" }.count
        #expect(unescapedQuoteCount == 4)
    }

    @Test func embedFetchHandlerMissingTargetRendersNotFound() async throws {
        let store = try TestStoreFactory.inMemory()
        let model = WikiStoreModel(store: store)
        let coord = WikiReaderRep.Coordinator()
        coord.store = model
        let recorder = JSRecorder()
        coord.deliverJS = { [weak recorder] in recorder?.record($0) }

        // Name-based page embed whose target does NOT resolve on the main
        // actor → "Page not found" placeholder, no fetch.
        await coord.processEmbedFetch(body: [
            "nodeId": "n-missing",
            "kind": "page",
            "id": "",
            "target": "Ghost",
            "path": "",
            "name": "Ghost",
        ])

        #expect(recorder.calls.count == 1)
        let js = try #require(recorder.calls.first)
        #expect(js.contains("Page not found"))
    }

    // MARK: - §12.4 Bridge coercion (#725 regression)

    /// `WKWebView` bridges a JS object literal (`postMessage({ … })`) to an
    /// `NSDictionary` whose values are boxed as `Any` / `NSString` — NOT
    /// `String`. The handler originally did `message.body as? [String: String]`,
    /// which ALWAYS fails against this shape and silently dropped every embed
    /// fetch → "Loading…" forever (#725). These tests exercise the real
    /// bridge payload shape through `EmbedFetchMessageHandler.coerceBody(_:)`
    /// — the entry point the (bypassed) `processEmbedFetch`-direct tests never
    /// reached, which is why the bug shipped.

    @Test func coerceBodyAcceptsNSDictionaryBridgeShape() {
        // Exact shape WKWebView delivers: NSDictionary with NSString values.
        let bridgeBody: NSDictionary = [
            "nodeId": NSString(string: "n-bridge"),
            "kind":   NSString(string: "page"),
            "id":     NSString(string: "01HZPAGE"),
            "target": NSString(string: ""),
            "path":   NSString(string: ""),
            "name":   NSString(string: "Foo"),
        ]

        let coerced = EmbedFetchMessageHandler.coerceBody(bridgeBody as Any)
        #expect(coerced != nil)
        #expect(coerced?["nodeId"] == "n-bridge")
        #expect(coerced?["kind"]   == "page")
        #expect(coerced?["id"]     == "01HZPAGE")
        #expect(coerced?["target"] == "")
        #expect(coerced?["path"]   == "")
        #expect(coerced?["name"]   == "Foo")
    }

    @Test func coerceBodyDefaultsMissingKeysToEmptyString() {
        // A real embed may post only a subset (e.g. a name-only page embed has
        // empty id/path/target). `processEmbedFetch` reads with `?? ""`; coerce
        // must mirror that so no key is ever absent.
        let bridgeBody: NSDictionary = [
            "nodeId": NSString(string: "n-sparse"),
            "kind":   NSString(string: "page"),
        ]
        let coerced = EmbedFetchMessageHandler.coerceBody(bridgeBody as Any)
        #expect(coerced?.count == 6)
        #expect(coerced?["nodeId"] == "n-sparse")
        #expect(coerced?["id"]     == "")
        #expect(coerced?["target"] == "")
        #expect(coerced?["path"]   == "")
        #expect(coerced?["name"]   == "")
    }

    @Test func coerceBodyRejectsNonDictionary() {
        // A string / number / array body is unparseable → nil (the handler
        // logs "embedFetch dropped: unparseable body" rather than silently
        // returning).
        #expect(EmbedFetchMessageHandler.coerceBody("oops" as Any) == nil)
        #expect(EmbedFetchMessageHandler.coerceBody(42 as Any) == nil)
        #expect(EmbedFetchMessageHandler.coerceBody([1, 2, 3] as Any) == nil)
    }
}
