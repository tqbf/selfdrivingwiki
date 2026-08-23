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
