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

        let initialAcknowledgement = await webView.chatTranscriptJavaScriptResult(
            "appendChatRows(\(initialJSON), false, 41, \"message-assistant-hosted\")"
        )
        #expect(acknowledgementField("revision", in: initialAcknowledgement) == 41)
        #expect(acknowledgementField("outcome", in: initialAcknowledgement) == "success")
        _ = await evaluateJavaScriptWithTimeout(webView, "document.querySelector('[data-focus-key=\\\"copy\\\"]').focus()")
        _ = await evaluateJavaScriptWithTimeout(webView, "(function(){var root=document.querySelector('[data-row-id=\\\"message-assistant-hosted\\\"] .bubble');var t=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null).nextNode();var r=document.createRange();r.setStart(t,0);r.setEnd(t,7);var s=getSelection();s.removeAllRanges();s.addRange(r);})()")
        let before = await evaluateJavaScriptWithTimeout(webView, "getSelection().toString()")
        #expect(before == "Initial")
        let replacementAcknowledgement = await webView.chatTranscriptJavaScriptResult(
            "replaceChatRow('message-assistant-hosted', \(replacementJSON), false, 42)"
        )
        #expect(acknowledgementField("revision", in: replacementAcknowledgement) == 42)
        #expect(acknowledgementField("rowID", in: replacementAcknowledgement) == "message-assistant-hosted")
        #expect(acknowledgementField("outcome", in: replacementAcknowledgement) == "success")

        let state = await evaluateJavaScriptWithTimeout(webView, "(function(){var row=document.querySelector('[data-row-id=\\\"message-assistant-hosted\\\"]');var active=document.activeElement;return [row.getAttribute('role'),row.getAttribute('aria-busy'),active.getAttribute('data-focus-key'),getSelection().toString().trim()].join('|');})()")
        #expect(state == "article|false|copy|Initial")
    }

    @Test func hostedCommandsUseStableRowIdentityAndReportMissingRows() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        await NavigationWaiter().load(ChatWebView.Coordinator.shellHTML, in: webView)
        let turnID = ChatTurnID(rawValue: "turn-order")
        let first = ChatDisplayRow.userMessage(
            id: ChatMessageID(rawValue: "row-first"), turnID: turnID,
            text: "Question", createdAt: .distantPast
        )
        let second = ChatDisplayRow.assistantMessage(
            id: ChatMessageID(rawValue: "row-second"), turnID: turnID,
            text: "Answer", createdAt: .distantPast, contentState: .final
        )
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(first)
            + ChatWebView.Coordinator.chatDisplayRowHTML(second)
        let data = try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed])
        let json = try #require(String(data: data, encoding: .utf8))

        let reload = await webView.chatTranscriptJavaScriptResult(
            "replaceChatTranscript(\(json), false, 61)"
        )
        #expect(acknowledgementField("kind", in: reload) == "reload")
        #expect(acknowledgementField("revision", in: reload) == 61)
        #expect(acknowledgementField("outcome", in: reload) == "success")
        let rowIDs = await evaluateJavaScriptWithTimeout(webView,
            "Array.from(document.querySelectorAll('[data-row-id]')).map(function(row){return row.getAttribute('data-row-id');}).join('|')"
        )
        #expect(rowIDs == "message-row-first|message-row-second")

        let missing = await webView.chatTranscriptJavaScriptResult(
            "replaceChatRow('message-not-present', '<article></article>', false, 62)"
        )
        #expect(acknowledgementField("kind", in: missing) == "replace")
        #expect(acknowledgementField("revision", in: missing) == 62)
        #expect(acknowledgementField("rowID", in: missing) == "message-not-present")
        #expect(acknowledgementField("outcome", in: missing) == "missingRow")
    }

    @Test func hostedExpandedToolRowsStackAndDisplayTheUnfencedPayload() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        await NavigationWaiter().load(ChatWebView.Coordinator.shellHTML, in: webView)
        let tool = ChatDisplayRow.toolCall(
            id: ToolCallID(rawValue: "tool-hosted"),
            turnID: ChatTurnID(rawValue: "turn-hosted-tool"),
            toolName: "Bash",
            status: .completed,
            detail: "git status",
            output: "```console\nhead_version_id: 01KX94Y\n```",
            permissionRequestID: nil,
            updatedAt: .distantPast
        )
        let toolHTML = ChatWebView.Coordinator.chatDisplayRowHTML(tool)
        let data = try JSONSerialization.data(withJSONObject: toolHTML, options: [.fragmentsAllowed])
        let json = try #require(String(data: data, encoding: .utf8))

        let acknowledgement = await webView.chatTranscriptJavaScriptResult(
            "appendChatRows(\(json), false, 71, \"tool-tool-hosted\")"
        )
        #expect(acknowledgementField("outcome", in: acknowledgement) == "success")

        let state = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
                var details=document.querySelector("[data-row-id='tool-tool-hosted']");
                var summary=details.querySelector('summary');
                var detail=details.querySelector('.chat-tool-detail');
                details.open=true;
                return [
                    detail.textContent,
                    String(detail.getBoundingClientRect().top > summary.getBoundingClientRect().top),
                    getComputedStyle(details).display
                ].join('|');
            })()
            """)

        #expect(state == "head_version_id: 01KX94Y|true|block")
    }

    @Test func hostedExpandedReasoningRowsPlaceTheirBodyBelowTheSummary() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        await NavigationWaiter().load(ChatWebView.Coordinator.shellHTML, in: webView)
        let reasoning = ChatDisplayRow.reasoning(
            id: ChatMessageID(rawValue: "reasoning-hosted"),
            turnID: ChatTurnID(rawValue: "turn-hosted-reasoning"),
            text: "Read file '/tmp/WIKI_STATE.md'", createdAt: .distantPast,
            contentState: .final
        )
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(reasoning)
        let data = try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed])
        let json = try #require(String(data: data, encoding: .utf8))

        let acknowledgement = await webView.chatTranscriptJavaScriptResult(
            "appendChatRows(\(json), false, 72, \"message-reasoning-hosted\")"
        )
        #expect(acknowledgementField("outcome", in: acknowledgement) == "success")

        let state = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
                var details=document.querySelector("[data-row-id='message-reasoning-hosted']");
                var summary=details.querySelector('summary');
                var body=details.querySelector('.row-thinking-body');
                details.open=true;
                return [
                    String(body.getBoundingClientRect().top > summary.getBoundingClientRect().top),
                    getComputedStyle(details).display
                ].join('|');
            })()
            """)

        #expect(state == "true|block")
    }

    private func acknowledgementField<T>(
        _ field: String,
        in result: ChatTranscriptJavaScriptResult
    ) -> T? {
        guard case .success(let value) = result,
              let acknowledgement = value as? [String: Any]
        else { return nil }
        return acknowledgement[field] as? T
    }
}
#endif
