#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import WikiFS

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct MermaidRendererHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?

        func load(
            _ html: String,
            in webView: WKWebView,
            timeout: Duration = .seconds(15)
        ) async -> Bool {
            webView.navigationDelegate = self
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finish(succeeded: false)
                }
                webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(succeeded: true)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(succeeded: false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(succeeded: false)
        }

        private func finish(succeeded: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(returning: succeeded)
        }
    }

    @Test(
        "standalone Mermaid renderer paints the requested palette at reader size",
        arguments: [ColorScheme.light, .dark])
    func standaloneRendererMatchesReaderPresentation(colorScheme: ColorScheme) async throws {
        _ = Self.app
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/Self Driving Wiki.app")
        let appBundle = try #require(Bundle(url: appURL))
        let library = try #require(MermaidRendererAssets.library(in: appBundle))

        let lease = await HostedAppKitTestGate.shared.acquire()
        let source = """
        flowchart LR
            Sources["Raw sources<br/>(immutable)"] --> Wiki["The wiki<br/>(LLM-owned markdown)"]
            Schema["The schema<br/>(CLAUDE.md / AGENTS.md)"] -.->|governs| Wiki
            You["You"] -->|curate and ask| Sources
            Wiki -->|you read| You
        """
        let view = MermaidRendererView(source: source, library: library)
            .environment(\.colorScheme, colorScheme)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        let webView = try await waitForWebView(in: window)
        var result = ""
        for _ in 0..<100 {
            result = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
              var diagram = document.getElementById('diagram');
              var svg = diagram && diagram.querySelector('svg');
              if (svg) {
                var node = svg.querySelector('.node rect, .node polygon, .node circle');
                var fill = node ? getComputedStyle(node).fill : 'missing';
                var configuredTheme = mermaid.mermaidAPI.getConfig().theme || 'missing';
                return 'svg:' + configuredTheme + ':' + fill + ':'
                  + Math.round(diagram.getBoundingClientRect().width) + ':'
                  + Math.round(svg.getBoundingClientRect().width);
              }
              var error = document.getElementById('error');
              if (error && !error.hidden) return 'error:' + error.textContent;
              return 'waiting:' + document.readyState + ':' + typeof window.mermaid;
            })()
            """, timeout: .seconds(2)) ?? "no-result"
            if result.hasPrefix("svg:") || result.hasPrefix("error:") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let expectedWidth = Int(PageEditorMetrics.readableContentWidth)
        let expectedTheme = MermaidRendererTheme(colorScheme: colorScheme).mermaidName
        let expectedFill = colorScheme == .dark ? "rgb(31, 32, 32)" : "rgb(236, 236, 255)"
        let fields = result.split(separator: ":")
        #expect(fields.count == 5, "standalone Mermaid runtime result: \(result)")
        if fields.count == 5 {
            #expect(fields[0] == "svg")
            #expect(fields[1] == Substring(expectedTheme))
            #expect(fields[2] == Substring(expectedFill), "Mermaid node fill: \(fields[2])")
            #expect(fields[3] == Substring(String(expectedWidth)))
            #expect(fields[4] == Substring(String(expectedWidth)))
        }
    }

    @Test("reader inline Mermaid bootstrap renders SVG and hides its fallback")
    func readerInlineMermaidBootstrapRendersTypedContainer() async throws {
        _ = Self.app
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/Self Driving Wiki.app")
        let appBundle = try #require(Bundle(url: appURL))
        let library = try #require(MermaidRendererAssets.library(in: appBundle))
        let body = """
        <div class="mermaid sdw-inline-mermaid">flowchart LR\nA --&gt; B</div>
        <pre class="sdw-inline-mermaid__fallback"><code class="language-mermaid">flowchart LR\nA --&gt; B</code></pre>
        """
        let html = WikiReaderView.documentHTML(body, mermaidLibrary: library)

        let lease = await HostedAppKitTestGate.shared.acquire()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        let navigationLoaded = await NavigationWaiter().load(html, in: webView)
        try #require(navigationLoaded)
        var result = ""
        for _ in 0..<100 {
            result = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
              var diagram = document.querySelector('.sdw-inline-mermaid');
              var fallback = document.querySelector('.sdw-inline-mermaid__fallback');
              if (!diagram || !fallback) return 'missing';
              return [
                diagram.getAttribute('data-mermaid-rendered') || 'waiting',
                diagram.querySelector('svg') ? 'svg' : 'no-svg',
                fallback.hidden ? 'hidden' : 'visible'
              ].join('|');
            })()
            """, timeout: .seconds(2)) ?? "no-result"
            if result == "true|svg|hidden" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(result == "true|svg|hidden", "reader inline Mermaid runtime result: \(result)")
    }

    @Test("reader inline Mermaid bootstrap preserves source after parse failure")
    func readerInlineMermaidBootstrapPreservesFallbackOnFailure() async throws {
        _ = Self.app
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/Self Driving Wiki.app")
        let appBundle = try #require(Bundle(url: appURL))
        let library = try #require(MermaidRendererAssets.library(in: appBundle))
        let body = """
        <div class="mermaid sdw-inline-mermaid">this is not valid Mermaid source</div>
        <pre class="sdw-inline-mermaid__fallback"><code class="language-mermaid">this is not valid Mermaid source</code></pre>
        """
        let html = WikiReaderView.documentHTML(body, mermaidLibrary: library)

        let lease = await HostedAppKitTestGate.shared.acquire()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        let navigationLoaded = await NavigationWaiter().load(html, in: webView)
        try #require(navigationLoaded)
        var result = ""
        for _ in 0..<100 {
            result = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
              var diagram = document.querySelector('.sdw-inline-mermaid');
              var fallback = document.querySelector('.sdw-inline-mermaid__fallback');
              if (!diagram || !fallback) return 'missing';
              var rendering = diagram.getAttribute('data-mermaid-rendering') === 'true';
              if (rendering) return 'waiting';
              return [
                diagram.querySelector('svg') ? 'svg' : 'no-svg',
                fallback.hidden ? 'hidden' : 'visible',
                fallback.textContent.trim()
              ].join('|');
            })()
            """, timeout: .seconds(2)) ?? "no-result"
            if result != "waiting" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(
            result == "no-svg|visible|this is not valid Mermaid source",
            "reader inline Mermaid failure result: \(result)")
    }

    private func waitForWebView(in window: NSWindow, timeout: Duration = .seconds(5)) async throws -> WKWebView {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let contentView = window.contentView,
               let webView = findWebView(in: contentView) {
                return webView
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(
            domain: "MermaidRendererHostedTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No hosted Mermaid WKWebView appeared"])
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = findWebView(in: subview) { return webView }
        }
        return nil
    }
}
#endif
