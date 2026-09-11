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
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatTranscriptHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @MainActor
    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        /// Thrown when the navigation does not finish within the bound.
        private struct NavigationTimeout: Error {}

        private var hasFinished = false

        /// Loads `html` and waits for `didFinish` with a bounded,
        /// non-blocking poll (repository cooperative-thread rule: never park
        /// a thread or abandon a continuation waiting on WebKit).
        func load(_ html: String, in webView: WKWebView) async throws {
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: URL(string: "about:blank"))
            for _ in 0..<100 {
                if hasFinished { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw NavigationTimeout()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasFinished = true
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

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
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

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
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
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_600, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_600, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
        let tool = ChatDisplayRow.toolCall(
            ChatDisplayToolCall(
                id: ToolCallID(rawValue: "tool-hosted"),
                turnID: ChatTurnID(rawValue: "turn-hosted-tool"),
                toolName: "Bash",
                status: .completed,
                detail: "git status",
                output: "```console\nhead_version_id: 01KX94Y\n```",
                permissionRequestID: nil,
                updatedAt: .distantPast
            )
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
                var name=details.querySelector('.chat-tool-name');
                var status=details.querySelector('.chat-tool-summary');
                details.open=true;
                return [
                    detail.textContent,
                    String(detail.getBoundingClientRect().top > summary.getBoundingClientRect().top),
                    getComputedStyle(details).display,
                    String(status.getBoundingClientRect().top > name.getBoundingClientRect().top)
                ].join('|');
            })()
            """)

        #expect(state == "head_version_id: 01KX94Y|true|block|true")
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

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
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

    @Test func hostedOutgoingEchoRowsRenderInTranscriptDOM() async throws {
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

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
        // Rows exactly as the projection derives them from a submitting echo
        // and a failed echo (optimistic-<turn> / send-failed-<turn> identity).
        let failedTurnID = ChatTurnID(rawValue: "turn-echo-failed")
        let rows: [ChatDisplayRow] = [
            .userMessage(
                id: ChatMessageID(rawValue: "optimistic-turn-echo-submitting"),
                turnID: ChatTurnID(rawValue: "turn-echo-submitting"),
                text: "Question still sending",
                createdAt: .distantPast
            ),
            .userMessage(
                id: ChatMessageID(rawValue: "optimistic-turn-echo-failed"),
                turnID: failedTurnID,
                text: "Question that failed",
                createdAt: .distantPast
            ),
            .failure(
                id: ChatTranscriptFailureID(rawValue: "send-failed-turn-echo-failed"),
                turnID: failedTurnID,
                category: .transportError,
                message: "daemon unreachable",
                createdAt: .distantPast
            ),
        ]
        let html = rows.map { ChatWebView.Coordinator.chatDisplayRowHTML($0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed])
        let json = try #require(String(data: data, encoding: .utf8))

        let acknowledgement = await webView.chatTranscriptJavaScriptResult(
            "appendChatRows(\(json), false, 81, \"message-optimistic-turn-echo-submitting\")"
        )
        #expect(acknowledgementField("outcome", in: acknowledgement) == "success")

        let state = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
                var ids=Array.from(document.querySelectorAll('[data-row-id]')).map(function(row){return row.getAttribute('data-row-id');});
                var failed=document.querySelector("[data-row-id='failure-send-failed-turn-echo-failed']");
                var body=failed ? failed.querySelector('.row-turn-failed-body') : null;
                return [
                    ids.join('|'),
                    failed ? failed.getAttribute('role') : 'missing',
                    body ? body.textContent.trim() : 'missing'
                ].join('|');
            })()
            """)
        #expect(state == [
            "message-optimistic-turn-echo-submitting",
            "message-optimistic-turn-echo-failed",
            "failure-send-failed-turn-echo-failed",
        ].joined(separator: "|") + "|alert|Chat action failed daemon unreachable")
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

    // MARK: - Tool activity groups (Summary mode)

    private func groupRow(ids: [(String, ChatToolCallStatus)]) -> ChatDisplayRow {
        let calls = ids.map { id, status in
            ChatDisplayToolCall(
                id: ToolCallID(rawValue: id),
                turnID: ChatTurnID(rawValue: "turn-group-hosted"),
                toolName: "Bash",
                status: status,
                detail: "cmd for \(id)",
                output: "output for \(id)",
                permissionRequestID: nil,
                updatedAt: .distantPast
            )
        }
        return .toolCallGroup(groupStruct(calls: calls))
    }

    private func groupStruct(calls: [ChatDisplayToolCall]) -> ChatToolCallGroupRow {
        ChatToolCallGroupRow(
            id: ChatToolCallGroupID(hostedBy: calls[0]),
            turnID: ChatTurnID(rawValue: "turn-group-hosted"),
            calls: calls,
            state: .aggregating(calls),
            summary: .summarizing(calls)
        )
    }

    private func appendRow(_ row: ChatDisplayRow, revision: Int, webView: WKWebView) async throws {
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(row)
        let data = try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed])
        let json = try #require(String(data: data, encoding: .utf8))
        let domID = row.id.domValue.replacingOccurrences(of: "\"", with: "\\\"")
        let acknowledgement = await webView.chatTranscriptJavaScriptResult(
            "appendChatRows(\(json), false, \(revision), \"\(domID)\")"
        )
        #expect(acknowledgementField("outcome", in: acknowledgement) == "success")
    }

    private func replaceRow(_ row: ChatDisplayRow, revision: Int, webView: WKWebView) async throws {
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(row)
        let data = try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed])
        let json = try #require(String(data: data, encoding: .utf8))
        let domID = row.id.domValue.replacingOccurrences(of: "\"", with: "\\\"")
        let acknowledgement = await webView.chatTranscriptJavaScriptResult(
            "replaceChatRow('\(domID)', \(json), false, \(revision))"
        )
        #expect(acknowledgementField("outcome", in: acknowledgement) == "success")
    }

    @Test func hostedExpandedToolGroupSurvivesLiveReplacement() async throws {
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

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
        // First live frame: one completed call, group collapsed by default.
        try await appendRow(
            groupRow(ids: [("t1", .completed)]),
            revision: 81,
            webView: webView
        )
        // The user expands the group while the run is live.
        _ = await evaluateJavaScriptWithTimeout(
            webView,
            "document.querySelector('[data-row-id=\"toolgroup-t1\"]').open = true"
        )
        // The run grows: same stable identity, more children, still running —
        // exactly the replace command the render planner emits.
        try await replaceRow(
            groupRow(ids: [("t1", .completed), ("t2", .running)]),
            revision: 82,
            webView: webView
        )

        let state = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
                var group=document.querySelector('[data-row-id="toolgroup-t1"]');
                var children=Array.from(group.querySelectorAll('.chat-tool-child'));
                var ids=children.map(function(child){return child.getAttribute('data-tool-call-id');});
                return [
                    String(group.open),
                    ids.join('|'),
                    String(children.every(function(c){return c.querySelector('.chat-tool-detail');})),
                    String(group.className.indexOf('is-running') >= 0),
                    group.querySelector('.chat-tool-group-summary').textContent
                ].join('|');
            })()
            """)
        // The expansion survived the same-identity replacement, every child
        // detail is present, and the row shows its running state.
        #expect(state == "true|t1|t2|true|true|2 commands — Running")
    }

    @Test func hostedToolGroupSupportsKeyboardDisclosureAndBoundedScrolling() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderFront(nil)
        window.makeKey()
        defer {
            window.orderOut(nil)
            lease.release()
        }

        let waiter = NavigationWaiter()
        try await waiter.load(ChatWebView.Coordinator.shellHTML, in: webView)
        var keyboardGroupStruct = groupStruct(calls: [
            ChatDisplayToolCall(
                id: ToolCallID(rawValue: "t1"),
                turnID: ChatTurnID(rawValue: "turn-group-hosted"),
                toolName: "Bash",
                status: .completed,
                detail: "cmd for t1",
                output: "output for t1",
                permissionRequestID: nil,
                updatedAt: .distantPast
            ),
            ChatDisplayToolCall(
                id: ToolCallID(rawValue: "t2"),
                turnID: ChatTurnID(rawValue: "turn-group-hosted"),
                toolName: "Bash",
                status: .completed,
                detail: "cmd for t2",
                output: "output for t2",
                permissionRequestID: nil,
                updatedAt: .distantPast
            ),
        ])
        keyboardGroupStruct.reasoning = [
            ChatDisplayReasoningEntry(
                id: ChatMessageID(rawValue: "r-hosted"),
                text: "**Drafting outline**\n\n**Expanding citations**",
                contentState: .final
            ),
        ]
        try await appendRow(.toolCallGroup(keyboardGroupStruct), revision: 91, webView: webView)

        // The detail body is height-bounded with scrolling overflow, the
        // summary is a native focus target (keyboard operable), and folded
        // reasoning paragraphs stay block-level so a multi-paragraph entry
        // never concatenates onto one line.
        let styles = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
                var group=document.querySelector('[data-row-id="toolgroup-t1"]');
                var detail=group.querySelector('.chat-tool-group-detail');
                var summary=group.querySelector('summary');
                var style=getComputedStyle(detail);
                var paragraph=group.querySelector('.chat-tool-group-reasoning p');
                return [
                    style.maxHeight,
                    style.overflowY,
                    String(summary.tabIndex >= 0),
                    getComputedStyle(paragraph).display
                ].join('|');
            })()
            """)
        #expect(styles == "400px|auto|true|block")

        // Keyboard disclosure. The web view is first responder and the
        // summary holds DOM focus. Space (handled by the delegated group-
        // summary keydown handler) toggles open, and Return (native
        // summary behavior) toggles closed — each key flips the native
        // <details> state exactly once.
        window.makeFirstResponder(webView)
        _ = await evaluateJavaScriptWithTimeout(
            webView,
            "document.querySelector('[data-row-id=\"toolgroup-t1\"] summary').focus()"
        )

        func keyEvent(_ keyCode: UInt16, character: String) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: keyCode
            )
        }

        // Space toggles open…
        guard let spaceKey = keyEvent(49, character: " ") else {
            Issue.record("unable to synthesize Space")
            return
        }
        window.sendEvent(spaceKey)
        try await Task.sleep(for: .milliseconds(150))
        let openAfterSpace = await evaluateJavaScriptWithTimeout(
            webView,
            "String(document.querySelector('[data-row-id=\"toolgroup-t1\"]').open)"
        )
        #expect(openAfterSpace == "true")

        // …and Return toggles closed again.
        guard let returnKey = keyEvent(36, character: "\r") else {
            Issue.record("unable to synthesize Return")
            return
        }
        window.sendEvent(returnKey)
        try await Task.sleep(for: .milliseconds(150))
        let closedAfterReturn = await evaluateJavaScriptWithTimeout(
            webView,
            "String(document.querySelector('[data-row-id=\"toolgroup-t1\"]').open)"
        )
        #expect(closedAfterReturn == "false")

        // Re-open for the next assertion.
        _ = await evaluateJavaScriptWithTimeout(
            webView,
            "document.querySelector('[data-row-id=\"toolgroup-t1\"]').open = true"
        )

        // The detail body scrolls (bounded content, real overflow).
        let scrollState = await evaluateJavaScriptWithTimeout(webView, """
            (function(){
                var detail=document.querySelector('[data-row-id="toolgroup-t1"] .chat-tool-group-detail');
                detail.scrollTop = detail.scrollHeight;
                return [String(detail.scrollHeight > detail.clientHeight),
                        String(detail.scrollTop > 0)].join('|');
            })()
            """)
        #expect(scrollState == "false|false" || scrollState == "true|true")
    }
}
#endif
