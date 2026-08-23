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

    @Test(
        "standalone Mermaid renderer paints the Testbed diagram at reader size and app theme",
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
                return 'svg:' + diagram.dataset.mermaidTheme + ':'
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

        let expectedTheme = MermaidRendererTheme(colorScheme: colorScheme).mermaidName
        let expectedWidth = Int(PageEditorMetrics.readableContentWidth)
        #expect(
            result == "svg:\(expectedTheme):\(expectedWidth):\(expectedWidth)",
            "standalone Mermaid runtime result: \(result)")
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
