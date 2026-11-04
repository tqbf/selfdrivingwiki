#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import WikiFS

/// The lint sheet's inline-precision highlight: the host-driven JS must wrap
/// the finding's EXACT text inside the marked block (and only there), so the
/// operator sees which sentence is wrong instead of a whole-paragraph
/// outline. Executes the real generated script against a live WKWebView DOM
/// — string assertions can't catch a script that emits the right text but
/// wraps nothing.
///
/// Opt-in: runs in the `WIKIFS_APP_TESTS=1` tier. Uses the same
/// NSApplication + navigation-waiter pattern as QuoteHighlightWebViewTests.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct LintInlineMarkWebViewTests {

    private static var retainedWindow: NSWindow?

    private static func releaseWindow(_ window: NSWindow) {
        window.orderOut(nil)
        if retainedWindow === window {
            retainedWindow = nil
        }
    }

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var fired = false

        func wait(for webView: WKWebView, html: String, timeout: Duration = .seconds(15)) async throws {
            _ = LintInlineMarkWebViewTests.app
            fired = false
            continuation = nil
            webView.navigationDelegate = self
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                continuation = cont
                webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    guard !fired else { return }
                    fired = true
                    continuation?.resume(throwing: NSError(
                        domain: "LintInlineMarkWebViewTests", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "navigation timed out"]))
                }
            }
        }

        private func resume(with error: Error? = nil) {
            guard !fired else { return }
            fired = true
            if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume() }
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume(with: error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume(with: error) }
    }

    /// A document with TWO paragraphs, each containing similar text — the
    /// second is the marked one, so a naive whole-document search would wrap
    /// the WRONG occurrence.
    private static func page(markedParagraph: String, otherParagraph: String) -> String {
        LintDocumentWebView.pageHTML(
            "<p>\(otherParagraph)</p>\n"
                + "<div class=\"wiki-lint-mark\" data-lint-mark=\"1\">"
                + "<p>\(markedParagraph)</p></div>")
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        let webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFront(nil)
        Self.retainedWindow = window
        return webView
    }

    // JS evaluation goes through the shared `evaluateJavaScriptWithTimeout`
    // helper (bounded, @MainActor) — see WKWebViewJSTimeout.swift.

    @Test func inlineMarkWrapsExactTextInsideMarkedBlockOnly() async throws {
        let webView = makeWebView()
        defer { if let w = Self.retainedWindow { Self.releaseWindow(w) } }
        let waiter = NavigationWaiter()
        try await waiter.wait(
            for: webView,
            html: Self.page(
                markedParagraph: "The committee approved the budget on Tuesday.",
                otherParagraph: "The committee approved the budget on Monday."))
        // The exact finding text appears in BOTH paragraphs; only the marked
        // (second) block's occurrence may be wrapped. (The script ends with
        // `;` — the `+ ''` coercion must wrap it in parens, not append.)
        let script = LintDocumentWebView.inlineMarkScript(
            texts: ["approved the budget on Tuesday"])
        let payload = try JSONEncoder().encode(script)
        let encoded = String(decoding: payload, as: UTF8.self)
        let probe = "(function(){ try { return 'OK:'+String(eval(" + encoded + ")); } catch(e) { return 'ERR:'+e.message; } })()"
        let wrapped = await evaluateJavaScriptWithTimeout(webView, probe)
        #expect(wrapped == "OK:1")
        if wrapped != "OK:1" {
            // Probe the script's own steps against this DOM.
            let stepProbe = """
            (function(){
              var norm=function(s){return s.replace(/\\s+/g,' ').trim();};
              var blocks=Array.prototype.slice.call(document.querySelectorAll('.wiki-lint-mark'));
              var out={blocks:blocks.length,hay:'',needle:norm('approved the budget on Tuesday'),at:-1,walkAt:-1};
              if(blocks.length){
                var tw=document.createTreeWalker(blocks[0],NodeFilter.SHOW_TEXT,null);
                var parts=[];
                while(tw.nextNode()){parts.push(tw.currentNode.nodeValue);}
                var hay=parts.join('');
                out.hay=hay;
                out.at=hay.indexOf(out.needle);
                // The generated script's per-character walk:
                var chars=[],map=[];
                var tw2=document.createTreeWalker(blocks[0],NodeFilter.SHOW_TEXT,null);
                while(tw2.nextNode()){var v=tw2.currentNode.nodeValue;
                  for(var i=0;i<v.length;i++){var c=v[i];
                    if(/\\s/.test(c)){
                      if(chars.length===0||chars[chars.length-1]!==' '){chars.push(' ');map.push({n:tw2.currentNode,o:i});}
                    }else{chars.push(c);map.push({n:tw2.currentNode,o:i});}}}
                var lo=0,hi=chars.length;
                while(lo<hi&&chars[lo]===' '){lo++;}
                while(hi>lo&&chars[hi-1]===' '){hi--;}
                var walkHay=chars.slice(lo,hi).join('');
                out.walkHay=walkHay;
                out.walkAt=walkHay.indexOf(out.needle);
              }
              return JSON.stringify(out);
            })()
            """
            let steps = await evaluateJavaScriptWithTimeout(webView, stepProbe)
            let scriptDump = "GENERATED SCRIPT:\n\(script)"
            Issue.record("\(scriptDump)")
            let detail = "script probe: \(wrapped ?? "nil") steps: \(steps ?? "nil")"
            Issue.record("\(detail)")
        }
        let hits = await evaluateJavaScriptWithTimeout(
            webView, #"document.querySelectorAll('mark.wiki-lint-hit').length + ''"#)
        #expect(hits == "1")
        let text = await evaluateJavaScriptWithTimeout(
            webView, #"var h=document.querySelector('mark.wiki-lint-hit'); h ? h.textContent : ''"#)
        #expect(text == "approved the budget on Tuesday")
        // The hit lives INSIDE the marked block, and the unmarked paragraph
        // keeps its original (Monday) text untouched.
        let location = await evaluateJavaScriptWithTimeout(
            webView,
            #"var h=document.querySelector('mark.wiki-lint-hit'); h && h.closest('.wiki-lint-mark') ? 'inside' : 'outside'"#)
        #expect(location == "inside")
        let mondayIntact = await evaluateJavaScriptWithTimeout(
            webView, #"document.body.textContent.includes('on Monday.') + ''"#)
        #expect(mondayIntact == "true")
    }

    @Test func inlineMarkCollapsesWhitespaceAndSkipsAbsentText() async throws {
        let webView = makeWebView()
        defer { if let w = Self.retainedWindow { Self.releaseWindow(w) } }
        let waiter = NavigationWaiter()
        // The authored text spans a line break; the DOM text has a newline.
        try await waiter.wait(
            for: webView,
            html: Self.page(
                markedParagraph: "First sentence here.\nThe finding spans a wrapped line.",
                otherParagraph: "Nothing relevant."))
        // Whitespace-collapsed needle matches across the newline (the page's
        // authored text has a literal line break inside the sentence).
        let spanningScript = LintDocumentWebView.inlineMarkScript(
            texts: ["The finding spans a wrapped line."])
        let wrappedSpanning = await evaluateJavaScriptWithTimeout(
            webView, "(" + spanningScript + ") + ''")
        #expect(wrappedSpanning == "1")
        // An absent text wraps nothing — the block outline stays the honest
        // fallback; a doubled occurrence wraps only once (first match).
        let absentScript = LintDocumentWebView.inlineMarkScript(
            texts: ["text that appears nowhere at all"])
        let wrappedAbsent = await evaluateJavaScriptWithTimeout(
            webView, "(" + absentScript + ") + ''")
        #expect(wrappedAbsent == "0")
        let hitCount = await evaluateJavaScriptWithTimeout(
            webView, #"document.querySelectorAll('mark.wiki-lint-hit').length + ''"#)
        #expect(hitCount == "1")
    }
}
#endif
