#if os(macOS)
import Foundation
import Testing
import WebKit
import WikiFSCore
import WikiFSLinks
import WikiFSTypes
@testable import WikiFS
@testable import WikiFSCodeHighlighting

/// Plan v2 transclusion tests: linkify dispatch, pure fetch+render, and the
/// Coordinator handler's cycle-marker / safe-injection paths. See
/// `plans/page-embed-v2.md` §12.
@MainActor
struct TransclusionEmbedTests {

    // MARK: - §12.1 Typed syntax, resolution, and lowering

    @Test func pageEmbedEmitsCollapsedDetailsWithStateOnHost() throws {
        let pageID = PageID(rawValue: "01HTESTPG0000000000000000A")
        let out = renderTyped(
            "![[Home]]",
            inputs: .init(
                pageIDByName: ["home": pageID],
                pageTitlesByID: [pageID: "Home"]))

        #expect(out.contains("<details class=\"sdw-transclusion\""))
        #expect(out.contains("data-sdw-embed-kind=\"page\""))
        #expect(out.contains("data-sdw-embed-id=\"\(pageID.rawValue)\""))
        #expect(!out.contains(" open"))
        let detailsStart = try #require(out.range(of: "<details class=\"sdw-transclusion\""))
        let afterDetails = String(out[detailsStart.upperBound...])
        let openingTagEnd = try #require(afterDetails.firstIndex(of: ">"))
        #expect(afterDetails[..<openingTagEnd].contains("data-sdw-state=\"empty\""))
    }

    @Test func pageEmbedAliasAndCanonicalNameUseTypedDisplayMetadata() {
        let pageID = PageID(rawValue: "01HTESTPG0000000000000000B")
        let inputs = DocumentEmbedResolver.Inputs(
            pageIDByName: ["cycle": pageID],
            pageTitlesByID: [pageID: "Live Title"])
        let alias = renderTyped("![[Cycle|the cycle]]", inputs: inputs)
        let canonical = renderTyped("![[\(pageID.rawValue)]]", inputs: inputs)

        #expect(alias.contains("<span class=\"sdw-embed-title\">the cycle</span>"))
        #expect(canonical.contains("data-sdw-embed-id=\"\(pageID.rawValue)\""))
        #expect(canonical.contains("<span class=\"sdw-embed-title\">Live Title</span>"))
    }

    @Test func sourceSyntaxSelectsInlineMediaOrTypedTransclusion() {
        let textID = SourceID(rawValue: "01HTESTTXT00000000000000005")
        let imageID = SourceID(rawValue: "01HTESTIMG0000000000000001")
        let inputs = DocumentEmbedResolver.Inputs(
            sourceByName: [
                "notes.txt": sourceResolution(id: textID, name: "notes.txt", mime: "text/plain"),
                "pic.png": sourceResolution(id: imageID, name: "pic.png", mime: "image/png"),
            ],
            sourceNamesByID: [textID: "notes.txt", imageID: "pic.png"])
        let text = renderTyped("![[source:notes.txt]]", inputs: inputs)
        let image = renderTyped("![[source:pic.png]]", inputs: inputs)

        #expect(text.contains("data-sdw-embed-kind=\"source\""))
        #expect(text.contains("data-sdw-embed-id=\"\(textID.rawValue)\""))
        #expect(image.contains("<img"))
        #expect(image.contains("wiki-blob://source/\(imageID.rawValue)"))
        #expect(!image.contains("sdw-transclusion"))
    }

    // MARK: - §12.2 Pure fetch+render (TransclusionEmbedder.renderEmbedBody)

    private func renderTyped(
        _ markdown: String,
        inputs: DocumentEmbedResolver.Inputs
    ) -> String {
        let prepared = ReaderMarkdown.preparedDocument(markdown)
        let projection = DocumentEmbedResolver(inputs: inputs).projection(for: prepared)
        return MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: .disabled)
    }

    private func sourceResolution(
        id: SourceID,
        name: String,
        mime: String
    ) -> DocumentSourceResolution {
        DocumentSourceResolution(
            sourceID: id,
            version: nil,
            displayName: name,
            mimeType: mime,
            bytes: nil,
            externalTarget: nil,
            isMermaidSource: false)
    }

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
            sources.map { (SourceID(rawValue: $0.id), $0.name) })
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

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(page.id), context: context, options: .disabled)
        let html = try #require(result.contentHTML)
        #expect(html.contains("Hello"))
        #expect(html.contains("<strong>world</strong>"))
        #expect(!result.isEmpty)
    }

    @Test func renderEmbedBodyCarriesTaggedAncestorsIntoNestedTransclusions() throws {
        let store = try TestStoreFactory.inMemory()
        let outer = try store.createPage(title: "Outer")
        let inner = try store.createPage(title: "Inner")
        try store.updatePage(id: outer.id, title: "Outer", body: "![[Inner]]")
        let context = contextFor(
            store: store,
            pages: [(outer.id.rawValue, "Outer"), (inner.id.rawValue, "Inner")])
        let collidingSource = DocumentTransclusionTarget.source(
            SourceID(rawValue: outer.id.rawValue))

        let result = try TransclusionEmbedder.renderEmbedBody(
            testFixtureStore: store,
            target: .page(outer.id),
            context: context,
            options: .disabled,
            ancestors: [collidingSource])
        let html = try #require(result.contentHTML)

        #expect(html.contains("data-sdw-embed-path=\"page:\(outer.id.rawValue) source:\(outer.id.rawValue)\""))
        #expect(html.contains("data-sdw-embed-id=\"\(inner.id.rawValue)\""))
    }

    @Test func renderEmbedBodyRichFencesStayStaticWithoutOuterAdmission() throws {
        let store = try TestStoreFactory.inMemory()
        let outer = try store.createPage(title: "Outer")
        let embedded = try store.createPage(title: "Embedded")
        try store.updatePage(
            id: embedded.id,
            title: "Embedded",
            body: """
            ```jsoncanvas
            {"nodes":[],"edges":[]}
            ```
            """)
        let context = contextFor(
            store: store,
            pages: [(outer.id.rawValue, "Outer"), (embedded.id.rawValue, "Embedded")])
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceClaims: PackageFenceTestSupport.builtInAndBundledClaims)
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: projection,
            documentIdentity: MarkdownDocumentIdentity(
                pageID: outer.id,
                pageVersionID: .init(rawValue: "outer-version")),
            rendererActivationAdmission: RendererEmbedActivationAdmission(
                pageID: outer.id,
                pageVersionID: .init(rawValue: "outer-version"),
                capability: .init(rawValue: "capability"),
                generation: 1))

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(embedded.id), context: context, options: options)
        let html = try #require(result.contentHTML)

        #expect(html.contains("sdw-renderer-card"))
        #expect(html.contains("JSON Canvas"))
        #expect(!html.contains("renderer-action://open"))
        #expect(!html.contains("data-renderer-input="))
        #expect(!html.contains("data-renderer-input=\"null\""))
    }

    @Test func duplicateTranscludedOrdinalsRemainStaticAndDoNotCollideActively() throws {
        let store = try TestStoreFactory.inMemory()
        let firstPage = try store.createPage(title: "First")
        let secondPage = try store.createPage(title: "Second")
        let body = """
        ```jsoncanvas
        {"nodes":[],"edges":[]}
        ```
        """
        try store.updatePage(id: firstPage.id, title: "First", body: body)
        try store.updatePage(id: secondPage.id, title: "Second", body: body)
        let context = contextFor(
            store: store,
            pages: [(firstPage.id.rawValue, "First"), (secondPage.id.rawValue, "Second")])
        let projection = RendererEmbedProjection(
            sourceEmbeds: [:],
            richFenceClaims: PackageFenceTestSupport.builtInAndBundledClaims)
        let options = MarkdownRenderOptions(
            codeHighlighting: .disabled,
            rendererEmbedProjection: projection,
            documentIdentity: MarkdownDocumentIdentity(
                pageID: firstPage.id,
                pageVersionID: .init(rawValue: "outer-version")),
            rendererActivationAdmission: RendererEmbedActivationAdmission(
                pageID: firstPage.id,
                pageVersionID: .init(rawValue: "outer-version"),
                capability: .init(rawValue: "capability"),
                generation: 1))

        let firstResult = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(firstPage.id), context: context, options: options)
        let secondResult = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(secondPage.id), context: context, options: options)
        let firstHTML = try #require(firstResult.contentHTML)
        let secondHTML = try #require(secondResult.contentHTML)

        #expect(firstHTML == secondHTML)
        #expect(firstHTML.contains("sdw-renderer-card"))
        #expect(firstHTML.contains("JSON Canvas"))
        #expect(!firstHTML.contains("renderer-action://open"))
        #expect(!secondHTML.contains("renderer-action://open"))
    }

    @Test func rootAndTransclusionShareTheDocumentHighlightedFenceBudget() throws {
        let store = try TestStoreFactory.inMemory()
        let embedded = try store.createPage(title: "Embedded")
        let fence = "```swift\nlet value = 1\n```"
        try store.updatePage(
            id: embedded.id,
            title: "Embedded",
            body: [fence, fence].joined(separator: "\n\n"))
        let context = contextFor(store: store, pages: [(embedded.id.rawValue, "Embedded")])
        let options = MarkdownRenderOptions.reader
        let root = MarkdownHTMLRenderer.render(
            Array(repeating: fence, count: CodeHighlightingPolicy.maximumHighlightedBlockCount - 1)
                .joined(separator: "\n\n"),
            options: options)
        let embeddedResult = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(embedded.id), context: context, options: options)
        let embeddedHTML = try #require(embeddedResult.contentHTML)
        let marker = "<span class=\"sdw-code-keyword\">let</span>"

        #expect(root.components(separatedBy: marker).count - 1 == CodeHighlightingPolicy.maximumHighlightedBlockCount - 1)
        #expect(embeddedHTML.components(separatedBy: marker).count - 1 == 1)
        #expect(embeddedHTML.contains("<pre><code class=\"language-swift\">let value = 1"))
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

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(outer.id), context: context, options: .disabled)
        let html = try #require(result.contentHTML)
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
            _ = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(ghostID), context: context, options: .disabled)
        }
    }

    @Test func renderEmbedBodySourcePrefersHeadMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let pdf = Data("pdf".utf8)
        let src = try store.addSource(filename: "doc.pdf", data: pdf, mimeType: "application/pdf")
        _ = try store.appendProcessedMarkdown(
            sourceID: src.id, content: "# Extracted\n\nThe body.", origin: .extraction, note: nil)
        let context = contextFor(store: store, pages: [], sources: [(src.id.rawValue, "doc.pdf")])

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .source(src.id), context: context, options: .disabled)
        let html = try #require(result.contentHTML)
        #expect(html.contains("Extracted"))
        #expect(html.contains("The body."))
    }

    @Test func renderEmbedBodyPreservesPinnedSourceLinkAcrossTransclusion() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "Paper.pdf", data: Data("%PDF".utf8), mimeType: "application/pdf")
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "first", origin: .extraction, note: nil)
        let v2 = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "second", origin: .extraction, note: nil)
        let page = try store.createPage(title: "Outer")
        try store.updatePage(
            id: page.id,
            title: "Outer",
            body: #"See [[source:\#(source.id.rawValue)@v2#"quoted"|Paper]]."#
        )
        let context = WikiRenderContext(
            pageTitles: ["outer"],
            pageIDToName: [page.id: "Outer"],
            sourceNames: ["paper.pdf"],
            sourceIDToName: [source.id: "Paper.pdf"],
            chatTitles: [],
            chatIDToName: [:],
            uniqueLooseKeys: [],
            embedMap: [:],
            sourceDerivedChain: [source.id: [SourceMarkdownVersionID(rawValue: "unused-v1"), v2.id]],
            siblingMaps: [:],
            blobScheme: WikiLinkMarkdown.blobScheme
        )

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .page(page.id), context: context, options: .disabled)
        let html = try #require(result.contentHTML)
        #expect(html.contains("pin=\(v2.id.rawValue)"))
    }

    @Test func renderEmbedBodySourceFallsBackToRawText() throws {
        let store = try TestStoreFactory.inMemory()
        let text = Data("Plain text body.".utf8)
        let src = try store.addSource(filename: "notes.txt", data: text, mimeType: "text/plain")
        // No extraction row → helper falls back to raw UTF-8 bytes.
        let context = contextFor(store: store, pages: [], sources: [(src.id.rawValue, "notes.txt")])

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .source(src.id), context: context, options: .disabled)
        let html = try #require(result.contentHTML)
        #expect(html.contains("Plain text body."))
    }

    @Test func renderEmbedBodySourceNilForUnextractedBinary() throws {
        // Plan v2 §4.2 invariant: a binary source with no extraction →
        // sourceEmbedBody returns nil, so renderEmbedBody returns `.empty`.
        // The read path does not start extraction.
        let store = try TestStoreFactory.inMemory()
        let pdf = Data([0x25, 0x50, 0x44, 0x46, 0x2D])  // "%PDF-" header bytes
        let src = try store.addSource(filename: "doc.pdf", data: pdf, mimeType: "application/pdf")
        let context = contextFor(store: store, pages: [], sources: [(src.id.rawValue, "doc.pdf")])

        let body = try TransclusionEmbedder.sourceEmbedBody(testFixtureStore: store, id: src.id)
        #expect(body == nil)

        let result = try TransclusionEmbedder.renderEmbedBody(testFixtureStore: store, target: .source(src.id), context: context, options: .disabled)
        #expect(result.isEmpty)
    }

    // MARK: - §12.2 Pure helpers (cycle + safe injection)

    @Test func cycleDetectionPreservesTargetNamespaces() {
        let pageA = DocumentTransclusionTarget.page(PageID(rawValue: "A"))
        let pageB = DocumentTransclusionTarget.page(PageID(rawValue: "B"))
        let sourceB = DocumentTransclusionTarget.source(SourceID(rawValue: "B"))
        let path = "page:A source:B"

        #expect(TransclusionEmbedder.isCycle(path: path, target: pageA))
        #expect(TransclusionEmbedder.isCycle(path: path, target: sourceB))
        #expect(!TransclusionEmbedder.isCycle(path: path, target: pageB))
        #expect(!TransclusionEmbedder.isCycle(path: "", target: pageA))
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

        // Simulate an embed whose tagged ancestor path contains the same page.
        // The handler must render the cycle marker without a store fetch.
        await coord.processEmbedFetch(body: [
            "nodeId": "n-cycle",
            "kind": "page",
            "id": "B",
            "target": "",
            "path": "page:A page:B",
            "name": "Page B",
        ])

        #expect(recorder.calls.count == 1)
        let js = try #require(recorder.calls.first)
        #expect(js.hasPrefix("sdwInjectEmbed(\"n-cycle\", \""))
        #expect(js.contains("sdw-embed-cycle"))
        #expect(js.contains("Page B"))
    }

    @Test func staleEmbedFetchGenerationDoesNotInject() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Stale")
        let model = WikiStoreModel(store: store)
        let coord = WikiReaderRep.Coordinator()
        coord.store = model
        let recorder = JSRecorder()
        coord.deliverJS = { [weak recorder] in recorder?.record($0) }

        let staleGeneration = coord.currentTransclusionGeneration
        coord.webView(WikiReaderWebView(), didStartProvisionalNavigation: nil)
        await coord.processEmbedFetch(body: [
            "nodeId": "n-stale",
            "kind": "page",
            "id": page.id.rawValue,
            "target": "",
            "path": "",
            "name": "Stale",
        ], generation: staleGeneration)

        #expect(coord.currentTransclusionGeneration != staleGeneration)
        #expect(recorder.calls.isEmpty)
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
#endif
