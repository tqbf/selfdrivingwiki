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

    @Test("standalone Mermaid renderer paints an SVG with the packaged runtime")
    func standaloneRendererPaintsSVG() async throws {
        _ = Self.app
        let appURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "build/Self Driving Wiki.app")
        let appBundle = try #require(Bundle(url: appURL))
        let library = try #require(MermaidRendererAssets.library(in: appBundle))

        let lease = await HostedAppKitTestGate.shared.acquire()
        let view = MermaidRendererView(
            source: "flowchart LR\nA[Start] --> B[Finish]",
            library: library)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 800, height: 600))
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
              if (document.querySelector('#diagram svg')) return 'svg';
              var error = document.getElementById('error');
              if (error && !error.hidden) return 'error:' + error.textContent;
              return 'waiting:' + document.readyState + ':' + typeof window.mermaid;
            })()
            """, timeout: .seconds(2)) ?? "no-result"
            if result == "svg" || result.hasPrefix("error:") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(result == "svg", "standalone Mermaid runtime result: \(result)")
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
