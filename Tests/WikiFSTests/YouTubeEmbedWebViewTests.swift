import AppKit
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

/// AC.9 (issue #206): the live WKWebView paint of a YouTube embed. The string
/// unit tests prove the *iframe HTML* is right; they CANNOT prove the wiring
/// that actually produced error 153 — the wrapping document's real origin. This
/// hosts the REAL `WikiReaderView` (through `NSHostingController`, the same seam
/// the app uses) and inspects the live DOM.
///
/// Root cause recap: the document was loaded under `about:blank`, so its origin
/// was the opaque `null`; the YouTube player rejects an embed with no valid
/// parent origin (153). The fix loads the document under `WikiReaderOrigin` AND
/// stamps a matching `?origin=` on the embed URL. This test pins BOTH ends:
///   1. the live document's `window.origin` is the real reader origin (not null), and
///   2. the painted iframe's `src` carries that same origin.
/// A regression to `about:blank` (or a dropped `?origin=`) fails here — which the
/// 1706 string-output tests could not catch.
@Suite(.tags(.integration))
@MainActor
struct YouTubeEmbedWebViewTests {

    /// A WKWebView in `swift test` has no host app, so JS/view work never fires.
    /// Creating `NSApplication.shared` gives WebKit the run loop / app context.
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let w = view as? WKWebView { return w }
        for sub in view.subviews { if let f = findWebView(sub) { return f } }
        return nil
    }

    @MainActor
    private func waitForWebView(in window: NSWindow, timeout: TimeInterval = 5) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cv = window.contentView, let w = findWebView(cv) { return w }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "YouTubeEmbedWebViewTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "no WKWebView found in hosted window"])
    }

    /// Evaluate `js` and return its result coerced to a String inside the
    /// completion (Sendable-safe — only the `String?` crosses the continuation).
    @MainActor
    private func evalString(_ webView: WKWebView, _ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in cont.resume(returning: result as? String) }
        }
    }

    /// Poll the live DOM until the reader has painted the embed iframe, returning
    /// its `src` (the render is async: detached convert → main-hop → loadHTMLString
    /// → didFinish). "" if it never appears.
    @MainActor
    private func waitForIframeSrc(in webView: WKWebView, tries: Int = 60) async -> String {
        for _ in 0..<tries {
            let src = await evalString(webView, """
            (function(){ var f=document.querySelector("iframe.wiki-embed"); return f?f.getAttribute("src"):""; })()
            """) ?? ""
            if !src.isEmpty { return src }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return ""
    }

    @MainActor
    private func hostedReader(markdown: String, store: WikiStoreModel) throws
        -> (window: NSWindow, webView: WKWebView) {
        let view = WikiReaderView(markdown: markdown, currentSelection: store.selection, store: store)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        return (window, findWebView(window.contentView!) ?? WKWebView())
    }

    /// The gold-standard AC.9 reproduction: seed a byteless YouTube source, render
    /// the real reader for a page that embeds it, and assert the live DOM. If the
    /// document were still under `about:blank`, `window.origin` would be `"null"`
    /// and YouTube would 153 — so this pins the fix at the layer the unit tests
    /// can't reach.
    @Test func hostedYouTubeEmbedLoadsUnderRealOriginWithMatchingEmbedURL() async throws {
        let dbURL = URL.temporaryDirectory.appending(path: "yt-embed-\(UUID().uuidString).sqlite")
        let sqlite = try SQLiteWikiStore(databaseURL: dbURL)
        let videoID = "dQw4w9WgXcQ"

        // Seed the byteless YouTube source exactly as the URL recognizer would.
        _ = try sqlite.addBytelessSource(
            filename: "youtube-\(videoID)",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/\(videoID)",
                externalRef: "https://youtu.be/\(videoID)",
                externalIdentity: videoID),
            role: .primary)

        let store = WikiStoreModel(store: sqlite)

        // A page that embeds the source — the real reader resolves this through
        // WikiRenderContext.embedInfo → ExternalEmbed.target.
        let markdown = "# Watch\n\n![[source:youtube-\(videoID)]]"

        let (window, _) = try hostedReader(markdown: markdown, store: store)
        defer { window.orderOut(nil) }
        let webView = try await waitForWebView(in: window)

        // 1. The iframe painted with the corrected embed URL (origin threaded in).
        let src = await waitForIframeSrc(in: webView)
        #expect(src.contains("youtube-nocookie.com/embed/\(videoID)"),
                "reader did not paint the YouTube iframe; src=\"\(src)\"")
        #expect(src.contains("origin="),
                "embed URL missing the ?origin= param that prevents error 153; src=\"\(src)\"")

        // 2. THE wiring fix: the live document is loaded under the real reader
        //    origin, NOT the opaque `null` of about:blank (the direct cause of 153).
        let origin = await evalString(webView, "String(window.origin)") ?? ""
        #expect(origin == WikiReaderOrigin.string,
                "document origin is \"\(origin)\" (expected \(WikiReaderOrigin.string)); a null/about:blank origin is what triggers YouTube error 153")

        // 3. And the embed's origin param matches that document origin — the two
        //    MUST agree for the player to accept the embed.
        let encodedOrigin = WikiReaderOrigin.string.addingPercentEncoding(
            withAllowedCharacters: {
                var a = CharacterSet.urlQueryAllowed; a.remove(charactersIn: ":/"); return a
            }()) ?? WikiReaderOrigin.string
        #expect(src.contains("origin=\(encodedOrigin)"),
                "embed origin param does not match the document origin; src=\"\(src)\"")

        // 4. The YouTube iframe is eager-loaded (no lazy suspension racing the
        //    player init) and carries a referrer policy.
        let attrs = await evalString(webView, """
        (function(){ var f=document.querySelector("iframe.wiki-embed");
          return f ? (f.getAttribute("loading")||"none")+"|"+(f.getAttribute("referrerpolicy")||"none") : "no-iframe"; })()
        """) ?? ""
        #expect(attrs == "none|strict-origin-when-cross-origin",
                "YouTube iframe should be eager-loaded with a referrer policy; got \"\(attrs)\"")
    }
}
