import AppKit
import SwiftUI
import WebKit
import WikiFSCore

/// Renders an entire `AgentEvent` transcript as **one** native text surface
/// inside a single, internally-scrolling `WKWebView` — so mouse drag-selection
/// (and Cmd+A / copy) spans every row in the feed, not just one message.
///
/// The prior design gave each assistant message its own `WKWebView`
/// (`AgentMarkdownText`). WebKit's text-selection model is sandboxed to its
/// own document, so selection could never cross from one web view into a
/// sibling one — every message was an island. Folding the whole feed into one
/// document removes that boundary entirely.
///
/// `events` is expected to be append-only except for an explicit reset to
/// `[]` (`AgentLauncher.events`'s contract): new events are inserted into the
/// live DOM via `appendRows` rather than a full reload, so an in-progress
/// text selection survives a streaming run. A count *decrease* (a reset) or a
/// `showsInternals` change (which changes which underlying events are
/// visible) forces a full rebuild.
struct AgentTranscriptWebView: NSViewRepresentable {
    /// `.activityFeed` is the inspector look (labeled rows, tool calls,
    /// diagnostics). `.chat` is the Query page look (right-aligned capsule
    /// for the user, plain prose for the assistant, no row labels).
    enum VisualStyle {
        case activityFeed
        case chat
    }

    let events: [AgentEvent]
    let style: VisualStyle
    /// A value that, when it changes, forces a full rebuild rather than an
    /// append — for callers whose event→visible-row filtering can change
    /// retroactively (e.g. `AgentActivityView`'s "Show internals" toggle).
    /// Callers whose filtering never changes mid-stream can ignore this.
    var showsInternals: Bool = false
    /// Invoked when the user clicks a `wiki://` link inside the transcript
    /// (rendered from an assistant/result row's `[[wiki-link]]`). The closure
    /// is built where the store lives (two levels up) and routes to
    /// `selectPage` / `selectSource`. `nil` → links still render but don't
    /// navigate (a strict improvement over literal `[[brackets]]`).
    var onWikiLink: ((URL) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        context.coordinator.style = style
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.reload(events: events, showsInternals: showsInternals)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.style = style
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.apply(events: events, showsInternals: showsInternals)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var style: VisualStyle = .activityFeed
        /// Routes a clicked `wiki://` link out to the view's `onWikiLink`
        /// closure (built where the store lives). Refreshed each update.
        var onWikiLink: ((URL) -> Void)?
        private var renderedCount = 0
        private var renderedShowsInternals: Bool?
        private var isLoaded = false
        private var pendingEvents: [AgentEvent] = []

        func reload(events: [AgentEvent], showsInternals: Bool) {
            renderedCount = 0
            renderedShowsInternals = showsInternals
            isLoaded = false
            pendingEvents = events
            webView?.loadHTMLString(Self.shellHTML, baseURL: URL(string: "about:blank"))
        }

        func apply(events: [AgentEvent], showsInternals: Bool) {
            if renderedShowsInternals != showsInternals {
                reload(events: events, showsInternals: showsInternals)
                return
            }
            guard isLoaded else {
                pendingEvents = events
                return
            }
            if events.count < renderedCount {
                reload(events: events, showsInternals: showsInternals)
                return
            }
            guard events.count > renderedCount else { return }
            appendRows(Array(events[renderedCount...]))
            renderedCount = events.count
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            let toRender = pendingEvents
            pendingEvents = []
            if !toRender.isEmpty {
                appendRows(toRender)
            }
            renderedCount = toRender.count
        }

        /// Open external links in the default browser instead of navigating
        /// the inline web view. `wiki://` links (rendered from `[[wiki-links]]`
        /// in assistant/result rows) are routed to `onWikiLink` instead of being
        /// loaded into the web view (which would produce a broken-navigation
        /// error page) — mirroring the http(s) branch's `.cancel`.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if url.scheme == "wiki" {
                    onWikiLink?(url)
                    decisionHandler(.cancel)
                    return
                }
                if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private func appendRows(_ events: [AgentEvent]) {
            let html = events.map { Self.rowHTML(for: $0, style: style) }.joined()
            guard !html.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]),
                  let jsonString = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("appendRows(\(jsonString))", completionHandler: nil)
        }

        // MARK: - Row rendering

        private static func rowHTML(for event: AgentEvent, style: VisualStyle) -> String {
            switch style {
            case .activityFeed: feedRowHTML(for: event)
            case .chat: chatRowHTML(for: event)
            }
        }

        /// Render assistant/result markdown with the shared footnote + wiki-link
        /// pre-pass (constant `true` resolution: the agent references pages it
        /// just wrote, and the transcript has no store to check existence). User
        /// text is intentionally NOT run through this — a user typing `[[Foo]]`
        /// is not a link. `internal` so the linkify behavior is unit-testable.
        static func renderedMarkdown(_ text: String) -> String {
            MarkdownHTMLRenderer.render(ReaderMarkdown.prepared(text) { _, _ in true })
        }

        static func feedRowHTML(for event: AgentEvent) -> String {
            switch event {
            case .userText(let text):
                return """
                <div class="row row-user"><div class="row-label">You</div>\
                <div class="row-body">\(escapePreservingBreaks(text))</div></div>
                """
            case .systemInit(let model):
                return "<div class=\"row row-meta\">Started · \(escape(model))</div>"
            case .assistantText(let text):
                return "<div class=\"row row-assistant\">\(renderedMarkdown(text))</div>"
            case .toolUse(let name, let summary):
                let summaryHTML = summary.isEmpty ? "" : "<span class=\"row-tool-summary\">\(escape(summary))</span>"
                return """
                <div class="row row-tool"><span class="row-tool-name">\(escape(name))</span>\(summaryHTML)</div>
                """
            case .toolResult(let isError, let summary):
                let body = summary.isEmpty ? (isError ? "(error)" : "(ok)") : summary
                return "<div class=\"row row-tool-result\(isError ? " is-error" : "")\">\(escape(body))</div>"
            case .subagent(let subagentType, let description, let isCompletion):
                let verb = isCompletion ? "digested" : "reading"
                let descHTML = description.isEmpty ? "" : " — \(escape(description))"
                return """
                <div class="row row-subagent\(isCompletion ? " is-complete" : "")">\
                <span class="row-subagent-type">\(escape(subagentType))</span> \(verb)\(descHTML)</div>
                """
            case .result(let isError, let text):
                let label = isError ? "Failed" : "Result"
                let bodyHTML = text.isEmpty ? "" : renderedMarkdown(text)
                return """
                <div class="row row-result\(isError ? " is-error" : "")"><div class="row-label">\(label)</div>\(bodyHTML)</div>
                """
            case .messageStop:
                return ""  // internal — not rendered
            case .raw(let line):
                return "<pre class=\"row row-raw\">\(escape(line))</pre>"
            }
        }

        /// The Query page chat look: a right-aligned capsule for the user, plain
        /// prose for the assistant (matching `QueryMessageBubble`'s prior
        /// SwiftUI rendering), no row labels. Other event kinds never reach a
        /// chat-styled transcript (the caller's `events` is pre-filtered to
        /// user/assistant/result), but render nothing rather than crash if one
        /// slips through.
        static func chatRowHTML(for event: AgentEvent) -> String {
            switch event {
            case .userText(let text):
                return """
                <div class="row chat-row chat-user"><div class="bubble">\(escapePreservingBreaks(text))</div></div>
                """
            case .assistantText(let text):
                return """
                <div class="row chat-row chat-assistant"><div class="bubble">\(renderedMarkdown(text))</div></div>
                """
            case .result(_, let text):
                guard !text.isEmpty else { return "" }
                return """
                <div class="row chat-row chat-assistant"><div class="bubble">\(renderedMarkdown(text))</div></div>
                """
            case .systemInit, .toolUse, .toolResult, .subagent, .messageStop, .raw:
                return ""
            }
        }

        private static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        private static func escapePreservingBreaks(_ s: String) -> String {
            escape(s).replacingOccurrences(of: "\n", with: "<br>")
        }

        /// Minimal document the whole feed lives in — internal scrolling
        /// (so native drag-select auto-scroll works), transparent background
        /// (the prior per-message `WKWebView`s left WebKit's `color-scheme`
        /// default canvas color showing through as a dark box per message;
        /// this explicitly overrides it), light/dark via `color-scheme`.
        static let shellHTML = """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
          :root {
            --text: #1c1c1e;
            --muted: rgba(60, 60, 67, 0.6);
            --code-bg: rgba(0, 0, 0, 0.06);
            --border: rgba(0, 0, 0, 0.12);
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --text: #e6e6e6;
              --muted: rgba(235, 235, 245, 0.6);
              --code-bg: rgba(255, 255, 255, 0.08);
              --border: rgba(255, 255, 255, 0.16);
            }
          }
          html, body { margin: 0; padding: 0; background: transparent; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            font-size: 13px; line-height: 1.5; color: var(--text);
            padding: 10px; -webkit-font-smoothing: antialiased;
          }
          .row { margin: 0 0 8px; }
          .row-label { font-size: 11px; font-weight: 600; color: var(--muted); margin-bottom: 2px; }
          .row-body { white-space: pre-wrap; }
          .row-meta, .row-tool, .row-tool-result, .row-subagent {
            font-size: 11px; color: var(--muted);
          }
          .row-tool-name, .row-subagent-type {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-weight: 600; color: var(--text); margin-right: 6px;
          }
          .row-tool-summary { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .row-tool-result.is-error { color: #ff453a; }
          .row-result .row-label { font-weight: 600; font-size: 12px; color: var(--text); }
          .row-result.is-error .row-label { color: #ff453a; }
          .row-raw {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 11px; color: var(--muted); margin: 0 0 8px;
            white-space: pre-wrap; word-break: break-word;
          }
          .chat-row { display: flex; margin: 0 0 14px; }
          .chat-user { justify-content: flex-end; }
          .chat-assistant { justify-content: flex-start; }
          .chat-row .bubble { max-width: min(760px, 86%); }
          .chat-user .bubble {
            background: var(--code-bg); border-radius: 999px;
            padding: 11px 16px; white-space: pre-wrap; font-size: 13.5px;
          }
          p { margin: 0 0 0.6em; }
          p:last-child { margin-bottom: 0; }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 0.7em 0 0.3em; }
          h1 { font-size: 1.25em; } h2 { font-size: 1.15em; }
          h3 { font-size: 1.05em; } h4, h5, h6 { font-size: 1em; }
          strong { font-weight: 600; }
          a { color: -webkit-link; }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em; background: var(--code-bg);
            padding: 0.1em 0.35em; border-radius: 4px;
          }
          pre {
            margin: 0 0 0.6em; padding: 8px 10px;
            background: var(--code-bg); border-radius: 6px; overflow: auto;
          }
          pre code { background: none; padding: 0; font-size: 0.9em; }
          ul, ol { padding-left: 1.4em; margin: 0 0 0.6em; }
          li { margin: 0.1em 0; }
          blockquote {
            margin: 0 0 0.6em; padding: 0 0 0 0.8em;
            border-left: 3px solid var(--border); color: var(--muted);
          }
        </style>
        </head><body>
        <script>
          function appendRows(html) {
            document.body.insertAdjacentHTML('beforeend', html);
            window.scrollTo(0, document.body.scrollHeight);
          }
        </script>
        </body></html>
        """
    }
}
