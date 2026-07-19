import AppKit
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// Integration tests that EXECUTE the quote-highlight JS against a live
/// `WKWebView` DOM (the string-assertion `QuoteHighlightJSTests` can't catch a
/// JS that emits the right text but doesn't actually produce a `<mark>`). If
/// these fail, the highlight JS itself is broken; if they pass, the bug is in
/// the trigger path (the pending-anchor consume that decides to run it).
@Suite(.tags(.integration), .timeLimit(.minutes(5)))
@MainActor
struct QuoteHighlightWebViewTests {

    /// A WKWebView in a `swift test` CLI has no host app, so JS evaluation never
    /// fires. Creating `NSApplication.shared` gives WebKit the run loop / app
    /// context it needs. Done once.
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    // MARK: - Navigation waiter (await loadHTMLString completion)

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?

        func wait(for webView: WKWebView, html: String) async throws {
            // Ensure the host app exists before driving WebKit.
            _ = QuoteHighlightWebViewTests.app
            webView.navigationDelegate = self
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(with: error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(with: error) }

        private func resume(with error: Error? = nil) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    /// Run `js` (no expected return value) and await completion.
    @MainActor
    private func run(_ webView: WKWebView, _ js: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in cont.resume() }
        }
    }

    /// Run `js` and return its result coerced to a String (Sendable-safe: the
    /// cast happens inside the completion so only a `String?` crosses the
    /// continuation).
    @MainActor
    private func evalString(_ webView: WKWebView, _ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result as? String)
            }
        }
    }

    /// Query the DOM for the highlight `<mark>` and return its text (or "").
    @MainActor
    private func markText(in webView: WKWebView) async -> String {
        await evalString(webView, """
        (function(){ var m=document.querySelector("mark.sdwhl"); return m?m.textContent:""; })()
        """) ?? ""
    }

    /// Combined text of ALL highlight `<mark>`s (a cross-node quote is split
    /// across several marks). "" if there are none.
    @MainActor
    private func allMarksText(in webView: WKWebView) async -> String {
        await evalString(webView, """
        (function(){ var t=""; document.querySelectorAll("mark.sdwhl").forEach(function(m){ t+=m.textContent+" "; }); return t; })()
        """) ?? ""
    }

    // MARK: - Tests

    @Test func debugHighlightState() async throws {
        let webView = WKWebView()
        let body = "<p>The data show a clear improvement in throughput.</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))
        await run(webView, WikiReaderRep.highlightJS(quote: "clear improvement"))
        let articleHTML = await evalString(webView, "document.querySelector('article').innerHTML")
        let wfType = await evalString(webView, "typeof window.find")
        let probe = await evalString(webView, """
        (function(){
          var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);
          var info=[];
          while(w.nextNode()){ info.push(JSON.stringify(w.currentNode.nodeValue)); if(info.length>3)break; }
          return "nodes="+info.join("|")+" wf="+typeof window.find;
        })()
        """)
        print("DBG_WINDOW_FIND_TYPE=\(wfType ?? "nil")")
        print("DBG_ARTICLE_HTML=\(articleHTML ?? "nil")")
        print("DBG_PROBE=\(probe ?? "nil")")
        #expect(true)
    }

    @Test func highlightWrapsExactQuoteInMark() async throws {
        let webView = WKWebView()
        let body = "<h2 id=\"results\">Results</h2><p>The data show a clear improvement in throughput.</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        await run(webView, WikiReaderRep.highlightJS(quote: "clear improvement"))

        let exact = await markText(in: webView)
        #expect(exact.lowercased() == "clear improvement")
    }

    @Test func highlightMatchesAcrossCollapsedWhitespace() async throws {
        // The source has extra internal whitespace / a newline; the quote is
        // single-spaced. The index-map fallback must still wrap the match.
        let webView = WKWebView()
        let body = "<p>The  data show a clear\nimprovement here.</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        await run(webView, WikiReaderRep.highlightJS(quote: "clear improvement"))

        let text = await markText(in: webView).lowercased()
        #expect(text.contains("clear") && text.contains("improvement"))
    }

    @Test func highlightWorksOnFullyRenderedMarkdownPipeline() async throws {
        // End-to-end: real markdown → ReaderMarkdown → MarkdownHTMLRenderer →
        // documentHTML, then the same highlight JS the reader runs.
        let markdown = "# Study\n\nThe results show a 30% improvement in latency."
        let body = MarkdownHTMLRenderer.render(ReaderMarkdown.prepared(markdown) { _, _ in true })
        let webView = WKWebView()
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        await run(webView, WikiReaderRep.highlightJS(quote: "30% improvement"))

        let rendered = await markText(in: webView)
        #expect(rendered.lowercased().contains("30% improvement"))
    }

    @Test func highlightAcrossInlineFormatting() async throws {
        // A quote that spans a <strong> boundary lives in TWO text nodes — the
        // common case for real source prose with inline formatting. The
        // highlight must still find + mark it (across both segments) and scroll.
        let webView = WKWebView()
        let body = "<p><strong>AI is an amplifier.</strong> It magnifies the strengths of organizations.</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        await run(webView, WikiReaderRep.highlightJS(quote: "AI is an amplifier. It magnifies the strengths"))

        let all = await allMarksText(in: webView).lowercased()
        #expect(all.contains("amplifier") && all.contains("magnifies"),
                "cross-node quote not highlighted; marks=\"\(all)\"")
        // And the scroll target exists (the first mark).
        #expect(await markText(in: webView).isEmpty == false)
    }

    @Test func highlightAcrossLinkFromRealSourceProse() async throws {
        // Verbatim prose from the wiki DB: the quote "AI is an amplifier. It
        // magnifies…struggling ones." spans a markdown LINK (the "AI is an
        // amplifier." part is the link text), so it lives in two text nodes.
        // Rendered through the real markdown pipeline, the highlight must still
        // land across the <a> boundary and scroll to it.
        let markdown = """
        As Nathen Harvey said in the 2025 DORA report: “ [AI is an amplifier.](https://services.google.com/fh/files/misc/2025_state_of_ai_assisted_software_development.pdf) It magnifies the strengths of high-performing organizations and the dysfunctions of struggling ones.” AI will not solve for a lack of discipline.
        """
        let body = MarkdownHTMLRenderer.render(ReaderMarkdown.prepared(markdown) { _, _ in true })
        let webView = WKWebView()
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        let quote = "AI is an amplifier. It magnifies the strengths of high-performing organizations and the dysfunctions of struggling ones."
        await run(webView, WikiReaderRep.highlightJS(quote: quote))

        let all = await allMarksText(in: webView).lowercased()
        #expect(all.contains("amplifier") && all.contains("magnifies") && all.contains("struggling"),
                "real cross-link quote not highlighted; marks=\"\(all)\"")
        #expect(await markText(in: webView).isEmpty == false)
    }

    @Test func highlightFallsBackToLongestRunWhenQuoteIsSplit() async throws {
        // PDF extraction spliced a reprint-address block (and a hard hyphen,
        // "vo-" / "litional") into the MIDDLE of the sentence, so the full quote
        // never appears contiguously. The fallback must still highlight the
        // longest contiguous run that IS present and scroll to it.
        let webView = WKWebView()
        let body = """
        <p>More recently, the vo-</p>\
        <p>For reprints write to: Irving Kirsch, Ph.D., Department of Psychology, U-20.</p>\
        <p>litional status of suggested behavior has become a source of intense controversy (Kirsch &amp; Lynn, 1995).</p>
        """
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        let quote = "the volitional status of suggested behavior has become a source of intense controversy"
        await run(webView, WikiReaderRep.highlightJS(quote: quote))

        let all = await allMarksText(in: webView).lowercased()
        #expect(all.contains("status of suggested behavior has become a source of intense controversy"),
                "split quote not highlighted via fallback; marks=\"\(all)\"")
        #expect(await markText(in: webView).isEmpty == false)
    }

    @Test func noFallbackHighlightForShortUnmatchedQuote() async throws {
        // A short quote (<4 words) that isn't present must NOT trigger a noisy
        // partial highlight — the fallback floor is 4 words.
        let webView = WKWebView()
        let body = "<p>alpha beta gamma delta epsilon</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        await run(webView, WikiReaderRep.highlightJS(quote: "nowhere to be found"))

        #expect(await markText(in: webView).isEmpty)
    }

    @Test func reHighlightClearsThePreviousMark() async throws {
        // A second highlight must remove the first mark, not stack them.
        let webView = WKWebView()
        let body = "<p>alpha beta gamma delta</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        await run(webView, WikiReaderRep.highlightJS(quote: "beta"))
        await run(webView, WikiReaderRep.highlightJS(quote: "delta"))

        let count = Int(await evalString(webView, "String(document.querySelectorAll('mark.sdwhl').length)") ?? "")
        let final = await markText(in: webView)
        #expect(count == 1)
        #expect(final.lowercased() == "delta")
    }

    // MARK: - Trigger seam (the path the reader actually takes on a click)

    /// `WikiReaderRep.apply(.quote, in:)` is what the Coordinator runs once the
    /// page has painted. Confirms the seam the pending-anchor consume drives.
    @Test func applyQuoteRunsHighlightJS() async throws {
        let webView = WKWebView()
        let body = "<p>The data show a clear improvement in throughput.</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        WikiReaderRep.apply(.quote("clear improvement"), in: webView)

        let mark = await waitForMark(in: webView)
        #expect(mark.lowercased() == "clear improvement")
    }

    /// `Coordinator.consumeAndApplyPendingAnchor` consumes the pending anchor
    /// straight from the store (keyed on the store's version), gated on
    /// `pageLoaded` — exactly the lifecycle that runs in `didFinish`. If this
    /// fails, the trigger (not the JS) is where the source highlight breaks.
    @Test func coordinatorAppliesQuoteHighlightOnceLoaded() async throws {
        let webView = WKWebView()
        let body = "<p>The data show a clear improvement in throughput.</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        let (store, selection) = try storeWithPendingQuoteAnchor(quote: "clear improvement")
        let coordinator = WikiReaderRep.Coordinator()
        coordinator.store = store
        coordinator.currentSelection = selection
        coordinator.loadedMarkdown = "The data show a clear improvement in throughput."
        coordinator.pageLoaded = true
        coordinator.consumeAndApplyPendingAnchor(in: webView)

        let mark = await waitForMark(in: webView)
        #expect(mark.lowercased() == "clear improvement")
    }

    /// After applying a version, `consumeAndApplyPendingAnchor` must NOT re-apply
    /// it (the version gate holds), so it doesn't re-run highlight on every
    /// `updateNSView`.
    @Test func coordinatorDoesNotReapplySameVersion() async throws {
        let webView = WKWebView()
        let body = "<p>alpha beta gamma</p>"
        try await NavigationWaiter().wait(for: webView, html: WikiReaderView.documentHTML(body))

        let (store, selection) = try storeWithPendingQuoteAnchor(quote: "beta")
        let coordinator = WikiReaderRep.Coordinator()
        coordinator.store = store
        coordinator.currentSelection = selection
        coordinator.loadedMarkdown = "alpha beta gamma"
        coordinator.pageLoaded = true
        coordinator.consumeAndApplyPendingAnchor(in: webView)   // applies (0 → 1)
        _ = await waitForMark(in: webView)

        // Same store version → must NOT re-run; the mark stays "beta".
        coordinator.consumeAndApplyPendingAnchor(in: webView)
        try await Task.sleep(nanoseconds: 150_000_000)

        let mark = await markText(in: webView)
        #expect(mark.lowercased() == "beta")
    }

    /// A store with a source selected + a pending quote anchor (the state a
    /// clicked `[[source:paper#"quote"]]` produces via `selectSource`).
    @MainActor
    private func storeWithPendingQuoteAnchor(quote: String) throws -> (WikiStoreModel, WikiSelection) {
        let store = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: URL.temporaryDirectory.appending(path: "coord-\(UUID().uuidString).sqlite")))
        store.addSource(filename: "paper.md", data: Data("# Paper\n".utf8))
        store.selectSource(byDisplayName: "paper", anchor: "\"\(quote)\"")
        return (store, store.selection!)
    }

    /// Poll the DOM for the highlight mark (the reader's `apply` is fire-and-
    /// forget `evaluateJavaScript`, so the result lands asynchronously).
    @MainActor
    private func waitForMark(in webView: WKWebView, tries: Int = 20) async -> String {
        for _ in 0..<tries {
            let mark = await markText(in: webView)
            if !mark.isEmpty { return mark }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return ""
    }

    // MARK: - Full hosted lifecycle (reproduces a real click → highlight)

    /// Walk a view tree to find the hosted `WKWebView`.
    private func findWebView(_ view: NSView) -> WKWebView? {
        if let w = view as? WKWebView { return w }
        for sub in view.subviews { if let f = findWebView(sub) { return f } }
        return nil
    }

    /// Poll the window's view hierarchy until the hosted `WKWebView` exists.
    @MainActor
    private func waitForWebView(in window: NSWindow, timeout: TimeInterval = 5) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cv = window.contentView, let w = findWebView(cv) { return w }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "QuoteHighlightWebViewTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "no WKWebView found in hosted window"])
    }

    /// The gold-standard reproduction: render the real `WikiReaderView` in a
    /// window, drive the SAME `selectSource(byDisplayName:anchor:)` seam a wiki
    /// link click uses, and assert the live DOM gets a `<mark>`. If this fails
    /// (but the seam tests above pass), the bug is in the SwiftUI `.task` /
    /// `updateNSView` / `didFinish` lifecycle — the only thing these tests can't
    /// reach any other way.
    @Test func hostedViewHighlightsQuoteFromPendingAnchor() async throws {
        let dbURL = URL.temporaryDirectory.appending(path: "hosted-\(UUID().uuidString).sqlite")
        let store = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: dbURL))
        let markdown = "# Paper\n\nThe data show a clear improvement in throughput."
        store.addSource(filename: "paper.md", data: Data(markdown.utf8))

        // Drive the real navigation seam: sets selection + a pending quote anchor,
        // exactly as a clicked `[[source:paper#"clear improvement"]]` does.
        store.selectSource(byDisplayName: "paper", anchor: "\"clear improvement\"")

        let view = WikiReaderView(markdown: markdown, currentSelection: store.selection, store: store)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let webView = try await waitForWebView(in: window)
        let mark = await waitForMark(in: webView, tries: 40)
        #expect(mark.lowercased() == "clear improvement",
                "hosted WikiReaderView did not highlight the quote; got \"\(mark)\"")
    }
}
