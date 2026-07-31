#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSTypes

/// Exercises the Phase 4 transcript markup against a live WebKit document.
/// It is serialized through the shared gate because SwiftPM has one AppKit host.
@Suite(.serialized)
@MainActor
struct ChatTranscriptHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?

        func load(_ html: String, in webView: WKWebView) async {
            webView.navigationDelegate = self
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func hostedDocumentPreservesSemanticRowsFocusAndSelectionAcrossAnUpdate() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        await NavigationWaiter().load(ChatWebView.Coordinator.shellHTML, in: webView)
        let turnID = ChatTurnID(rawValue: "turn-hosted")
        let initial = ChatDisplayRow.assistantMessage(
            id: ChatMessageID(rawValue: "assistant-hosted"),
            turnID: turnID,
            text: "Initial answer",
            createdAt: .distantPast,
            contentState: .streaming
        )
        let replacement = ChatDisplayRow.assistantMessage(
            id: ChatMessageID(rawValue: "assistant-hosted"),
            turnID: turnID,
            text: "Initial answer, completed",
            createdAt: .distantPast,
            contentState: .final
        )
        let initialHTML = ChatWebView.Coordinator.chatDisplayRowHTML(initial)
        let replacementHTML = ChatWebView.Coordinator.chatDisplayRowHTML(replacement)
        let initialData = try JSONSerialization.data(
            withJSONObject: initialHTML,
            options: [.fragmentsAllowed]
        )
        let replacementData = try JSONSerialization.data(
            withJSONObject: replacementHTML,
            options: [.fragmentsAllowed]
        )
        let initialJSON = try #require(String(data: initialData, encoding: .utf8))
        let replacementJSON = try #require(String(data: replacementData, encoding: .utf8))

        _ = await evaluateJavaScriptWithTimeout(webView, "appendRows(\(initialJSON), false)")
        _ = await evaluateJavaScriptWithTimeout(webView, "document.querySelector('[data-focus-key=\\\"copy\\\"]').focus()")
        _ = await evaluateJavaScriptWithTimeout(webView, "(function(){var root=document.querySelector('[data-row-id=\\\"message-assistant-hosted\\\"] .bubble');var t=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null).nextNode();var r=document.createRange();r.setStart(t,0);r.setEnd(t,7);var s=getSelection();s.removeAllRanges();s.addRange(r);})()")
        let before = await evaluateJavaScriptWithTimeout(webView, "getSelection().toString()")
        #expect(before == "Initial")
        _ = await evaluateJavaScriptWithTimeout(webView, "replaceChatRow('message-assistant-hosted', \(replacementJSON), false)")

        let state = await evaluateJavaScriptWithTimeout(webView, "(function(){var row=document.querySelector('[data-row-id=\\\"message-assistant-hosted\\\"]');var active=document.activeElement;return [row.getAttribute('role'),row.getAttribute('aria-busy'),active.getAttribute('data-focus-key'),getSelection().toString().trim()].join('|');})()")
        #expect(state == "article|false|copy|Initial")
    }
}
#endif
