import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSEngine
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
/// `events` is expected to only grow in length, or have its LAST element mutated
/// in place (a streamed text delta merged into an in-progress `.assistantText`,
/// issue #121), except for an explicit reset to `[]` (`AgentLauncher.events`'s
/// contract): new events are inserted into the live DOM via `appendRows`, and an
/// in-place growth of the last row is patched via `replaceLastRow`, rather than a
/// full reload — so an in-progress text selection survives a streaming run. A
/// count *decrease* (a reset) or a `showsInternals` change (which changes which
/// underlying events are visible) forces a full rebuild.
/// A versioned request to scroll the chat transcript to a user turn. Mirrors the
/// reader's anchor-version pattern: `version` bumps to signal a new request;
/// `turnIndex` is the 0-based index among the `.chat-user` rows the transcript
/// renders. Consumed in `ChatWebView.updateNSView`.
struct ChatScrollRequest: Equatable {
    let version: Int
    let turnIndex: Int
}

/// A versioned request to highlight a quoted passage in the chat transcript and
/// scroll it into view — the rendering half of `[[chat:Title#"quote"]]` (issue
/// #281). Mirrors the reader's anchor-version pattern: `version` bumps to signal
/// a new request (so a re-click to the same chat re-fires); `quote` is the
/// passage text (delimiters already stripped). Consumed in
/// `ChatWebView.updateNSView`/`didFinish` via `window.find` + `<mark sdwhl>`.
struct ChatHighlightRequest: Equatable {
    let version: Int
    let quote: String
}

struct ChatWebView: NSViewRepresentable {
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
    /// retroactively (e.g. `AgentQueueView`'s "Show internals" toggle).
    /// Callers whose filtering never changes mid-stream can ignore this.
    var showsInternals: Bool = false
    /// Invoked when the user clicks a `wiki://` link inside the transcript
    /// (rendered from an assistant/result row's `[[wiki-link]]`). The closure
    /// is built where the store lives (two levels up) and routes to
    /// `selectPage` / `selectSource`. `nil` → links still render but don't
    /// navigate (a strict improvement over literal `[[brackets]]`).
    var onWikiLink: ((URL, Bool) -> Void)? = nil
    /// Provider of the **current** `WikiRenderContext` (Phase A.2). A closure,
    /// not a value: rows render incrementally over the view's life and the
    /// resolution sets must stay current (a rename between two renders must
    /// heal). Built where the store lives and bound to `store.renderContext()`
    /// (the model's memo, `WikiEventBus`-invalidated). `nil` (or a nil return)
    /// keeps the historical constant-`true` resolution — used by
    /// `AgentQueueView`'s internals feed, where ghost styling is noise.
    ///
    /// The coordinator resolves this to a `WikiRenderContext?` **value** once
    /// per render pass on the main actor (the provider reads the `@MainActor`
    /// store), then hands the `Sendable` value to the pure static render
    /// functions — the same compute-once/capture-pure-data discipline the
    /// reader follows.
    var renderContext: (() -> WikiRenderContext?)? = nil
    /// The store backing `wiki-blob://source/<id>` blob serving for the
    /// transcript's images/media. Registered as a `BlobSchemeHandler` on the
    /// WKWebView (mirroring `WikiReaderView`). Weakly held by the handler.
    var blobStore: WikiStoreModel? = nil
    /// Page-zoom multiplier applied to the transcript web view via
    /// `WKWebView.pageZoom` (same mechanism as `WikiReaderView`'s
    /// `readerZoom`). Defaults to 1× so callers that don't pass a value render
    /// at native size.
    var zoom: Double = Double(ZoomScale.defaultScale)
    /// Versioned request to scroll to a user turn (outline click). `nil` (default)
    /// never scrolls; consumed in `updateNSView`.
    var scrollRequest: ChatScrollRequest? = nil
    /// Versioned request to highlight + scroll to a `[[chat:Title#"quote"]]`
    /// passage (issue #281). `nil` (default) never highlights; consumed in
    /// `updateNSView` (re-click on a loaded transcript) and `didFinish` (fresh
    /// load). The coordinator stashes it and applies once rows are rendered.
    var quoteAnchor: ChatHighlightRequest? = nil

    /// Wall-clock timestamps parallel to `events`. Indexed per-row so the
    /// coordinator can compute a duration ("Worked for Xs") and a completion
    /// timestamp for each assistant bubble. Entry `nil` → no footer for that
    /// row. Empty array (default) → no footers at all (activity-feed callers
    /// that don't track timing are unaffected).
    var timestamps: [Date?] = []

    /// Name of the `WKScriptMessage` channel the per-bubble "Copy" button posts
    /// to (issue #285). The JS click listener calls
    /// `window.webkit.messageHandlers.copyText.postMessage(text)`; the coordinator
    /// writes `text` to `NSPasteboard`.
    static let copyMessageName = "copyText"

    /// Sets a private WebKit SPI key on the WebView, guarding against a future OS
    /// that no longer recognizes the key (KVC `setValue(_:forKey:)` throws on an
    /// unknown key, which would tear down the view). Returns whether it was set.
    /// See Bug #1 in `makeNSView` for why these keys are needed.
    @discardableResult
    private static func setSPI(_ key: String, _ value: Any, on webView: WKWebView) -> Bool {
        // The obvious guard — `responds(to: setValue:forKey:)` — is useless: every
        // NSObject responds to it, so it never blocked an unknown key. KVC then
        // throws NSUnknownKeyException, an ObjC exception Swift cannot catch, which
        // aborts the app (macOS 26 dropped one of these keys; regression from #708).
        // Probe the key itself instead: both SPI keys are plain properties whose
        // getter selector IS the key, so `responds(to:)` on the key is a real
        // presence check that disappears the moment the OS removes the property.
        guard webView.responds(to: NSSelectorFromString(key)) else { return false }
        webView.setValue(value, forKey: key)
        return true
    }

    func makeNSView(context: Context) -> WKWebView {
        // Register the blob scheme handler BEFORE the first load (same wiring
        // as `WikiReaderView`, reader lines ~326–348) so `wiki-blob://source/<id>`
        // images and media resolve inside chat transcripts. The handler weakly
        // references the store; refreshed each update like `onWikiLink`.
        let config = WKWebViewConfiguration()
        // Message handler for the per-bubble "Copy" button (issue #285): the JS
        // click listener posts the raw markdown text; the coordinator writes it
        // to NSPasteboard. Retained by the content controller; the coordinator
        // holds the webView weakly so there's no cycle (same pattern as
        // WikiReaderView's LinkHoverMessageHandler).
        let cc = WKUserContentController()
        cc.add(context.coordinator, name: Self.copyMessageName)
        config.userContentController = cc
        let blobHandler = BlobSchemeHandler(store: blobStore)
        config.setURLSchemeHandler(blobHandler, forURLScheme: BlobSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.pageZoom = zoom
        webView.allowsBackForwardNavigationGestures = false
        // Bug #1: keep the overlay scroller inside the WebView's visible bounds so it
        // can no longer paint over the window's traffic lights (Agent / Extraction
        // Queue window). WKWebView manages its own NSScrollView privately (no public
        // `scrollView` on macOS), so this goes through the SPI WebKit itself exposes
        // for exactly this:
        //  • _clipsToVisibleRect — clips drawing (incl. the scroller) to the visible rect.
        //  • _automaticallyAdjustsContentInsets — off, so the scroller is NOT positioned
        //    against the title-bar band.
        // Guarded so a future OS that renames/removes these keys can't crash the view.
        Self.setSPI("_clipsToVisibleRect", true, on: webView)
        Self.setSPI("_automaticallyAdjustsContentInsets", false, on: webView)
        context.coordinator.webView = webView
        context.coordinator.style = style
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.renderContext = renderContext
        context.coordinator.reload(events: events, showsInternals: showsInternals, timestamps: timestamps)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom
        context.coordinator.style = style
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.renderContext = renderContext
        // Keep the blob handler's store fresh (a wiki switch swaps the store).
        if let handler = webView.configuration.urlSchemeHandler(forURLScheme: BlobSchemeHandler.scheme) as? BlobSchemeHandler {
            handler.store = blobStore
        }
        context.coordinator.apply(events: events, showsInternals: showsInternals, timestamps: timestamps)
        // Outline click → scroll the i-th user bubble into view. Only fires when
        // the version advances, so unrelated re-renders (streaming) don't re-scroll.
        if let req = scrollRequest, req.version != context.coordinator.appliedScrollVersion {
            context.coordinator.appliedScrollVersion = req.version
            let js = "(function(){var u=document.querySelectorAll('.chat-user');var el=u[\(req.turnIndex)];if(el){el.scrollIntoView({block:'start'});}})()"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        // Quote-anchor highlight (issue #281): stash the latest quote and ask
        // the coordinator to apply it. The coordinator guards on "loaded", so a
        // request that lands before rows render is deferred and picked up by
        // `didFinish` once the transcript is in the DOM.
        if let req = quoteAnchor, req.version != context.coordinator.appliedHighlightVersion {
            context.coordinator.appliedHighlightVersion = req.version
            context.coordinator.pendingHighlightQuote = req.quote
            context.coordinator.applyHighlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var style: VisualStyle = .activityFeed
        /// Routes a clicked `wiki://` link out to the view's `onWikiLink`
        /// closure (built where the store lives). Refreshed each update.
        var onWikiLink: ((URL, Bool) -> Void)?
        /// Provider of the current `WikiRenderContext` (Phase A.2). Refreshed
        /// each update. Resolved to a value once per render pass (see
        /// `currentContext`); the value is `Sendable` so it can flow into the
        /// pure static render functions.
        var renderContext: (() -> WikiRenderContext?)?
        /// Last chat-outline scroll request applied, so an unchanged request
        /// doesn't re-scroll on every re-render.
        var appliedScrollVersion: Int = -1
        /// The pending quote to highlight + scroll to (issue #281), stashed by
        /// `updateNSView` and applied once rows render. A quote link can arrive
        /// before the transcript's rows are appended (the page hasn't finished
        /// loading), so the coordinator defers the `window.find` until `didFinish`.
        var pendingHighlightQuote: String?
        /// The last `ChatHighlightRequest.version` applied, so an unchanged
        /// request doesn't re-highlight on every re-render.
        var appliedHighlightVersion: Int = -1
        private var renderedCount = 0
        private var renderedShowsInternals: Bool?
        private var isLoaded = false
        private var pendingEvents: [AgentEvent] = []
        /// Pending timestamps to render once the page finishes loading (stashed by
        /// `apply` when the view isn't loaded yet). Parallel to `pendingEvents`.
        private var pendingTimestamps: [Date?] = []
        /// The full timestamps array — refreshed each `apply` call. Used to
        /// compute "Worked for Xs" duration + completion timestamp per row.
        private var timestamps: [Date?] = []
        /// The last event actually rendered, so `apply` can detect "no new row, but
        /// `AgentLauncher` grew the last one in place" (a streamed `.assistantText`
        /// delta merge, issue #121) and patch that row instead of no-op'ing.
        private var renderedLastEvent: AgentEvent?
        /// The full event list as last seen, used to compute `isFinal` (a row is
        /// non-final only when it is the LAST row of a still-live event stream —
        /// i.e. it may still grow via `replaceLastRow`). Captured in `apply`.
        private var renderedEvents: [AgentEvent] = []

        /// Resolve the provider once per render pass on the main actor. Returns
        /// the current `WikiRenderContext` (or nil → constant-true behavior).
        private func currentContext() -> WikiRenderContext? { renderContext?() }

        func reload(events: [AgentEvent], showsInternals: Bool, timestamps: [Date?] = []) {
            renderedCount = 0
            renderedShowsInternals = showsInternals
            renderedLastEvent = nil
            renderedEvents = events
            self.timestamps = timestamps
            isLoaded = false
            pendingEvents = events
            pendingTimestamps = timestamps
            webView?.loadHTMLString(Self.shellHTML, baseURL: URL(string: "about:blank"))
        }

        func apply(events: [AgentEvent], showsInternals: Bool, timestamps: [Date?] = []) {
            self.timestamps = timestamps
            if renderedShowsInternals != showsInternals {
                reload(events: events, showsInternals: showsInternals, timestamps: timestamps)
                return
            }
            guard isLoaded else {
                pendingEvents = events
                pendingTimestamps = timestamps
                return
            }
            if events.count < renderedCount {
                reload(events: events, showsInternals: showsInternals, timestamps: timestamps)
                return
            }
            guard events.count > renderedCount else {
                // Same row count: `AgentLauncher` may have grown the last row in
                // place (streamed text deltas merged into an in-progress
                // `.assistantText`, issue #121) rather than appending a new one —
                // patch that row's HTML instead of treating this as a no-op.
                if let last = events.last, last != renderedLastEvent {
                    // The last row of a live stream is still growing → render it
                    // in the streaming (links-only) tier so a half-typed
                    // `![[source:…` never instantiates a broken iframe/player.
                    replaceLastRow(last, at: events.count - 1, isStreaming: true, allEvents: events)
                    renderedLastEvent = last
                }
                renderedEvents = events
                return
            }
            // New rows appended: any previously-streaming last row is now FINAL
            // (a new event landed = turn boundary). Re-render it once with the
            // full context (embeds included), then append the new rows.
            let context = currentContext()
            if let prevLast = renderedEvents.last, events.count > renderedEvents.count,
               renderedEvents.count > 0 {
                replaceLastRow(prevLast, at: renderedEvents.count - 1, isStreaming: false, allEvents: events, context: context)
            }
            appendRows(Array(events[renderedCount...]), startingIndex: renderedCount, context: context)
            renderedCount = events.count
            renderedLastEvent = events.last
            renderedEvents = events
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            let toRender = pendingEvents
            pendingEvents = []
            pendingTimestamps = []
            // Initial load: every row is final (persisted chats load all-at-once;
            // a freshly-opened live view's events are all complete at this point).
            let context = currentContext()
            if !toRender.isEmpty {
                appendRows(toRender, startingIndex: 0, context: context)
            }
            renderedCount = toRender.count
            renderedLastEvent = toRender.last
            renderedEvents = toRender
            // Apply a deferred quote-anchor highlight now that the transcript's
            // rows are in the DOM (issue #281).
            if pendingHighlightQuote != nil {
                applyHighlight()
            }
        }

        /// Highlight + scroll to the stashed quote passage via `window.find` +
        /// `<mark class="sdwhl">` — the same mechanism the page/source reader
        /// uses (`WikiReaderView.applyFind`). The transcript is one document, so
        /// `window.find` lands on the first match (which is the message
        /// `ChatQuoteResolver` identified). Guards on `isLoaded` so a request
        /// that lands before rows render is deferred to `didFinish`; clears the
        /// stash only when it actually runs.
        func applyHighlight() {
            guard isLoaded, let webView,
                  let quote = pendingHighlightQuote, !quote.isEmpty else { return }
            pendingHighlightQuote = nil
            webView.evaluateJavaScript(Self.highlightAndScrollJS(quote: quote), completionHandler: nil)
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
                    // ⌘-click opens a new tab; plain click navigates in place.
                    let openInNewTab = navigationAction.modifierFlags.contains(.command)
                    onWikiLink?(url, openInNewTab)
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

        private func appendRows(_ events: [AgentEvent], startingIndex: Int, context: WikiRenderContext?) {
            // Appended rows are always final (they're complete events). Only the
            // actively-streaming trailing row — patched via the same-count
            // `replaceLastRow(..., isStreaming: true)` path — uses the
            // links-only tier.
            var html = ""
            // Hoist the concatenation above the loop: `renderedEvents + events`
            // was rebuilt per-row, making the loop O(n²) in array copies (#503 P2).
            let allEvents = renderedEvents + events
            for (offset, event) in events.enumerated() {
                let absoluteIndex = startingIndex + offset
                let ts = absoluteIndex < timestamps.count ? timestamps[absoluteIndex] : nil
                html += Self.rowHTML(for: event, style: style, context: context, isFinal: true, timestamp: ts, allEvents: allEvents, allTimestamps: timestamps, index: absoluteIndex)
            }
            guard !html.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]),
                  let jsonString = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("appendRows(\(jsonString))", completionHandler: nil)
        }

        /// Re-render the already-rendered last row in place (a streaming delta grew
        /// its content without adding a new `AgentEvent`) instead of appending a
        /// duplicate — the DOM equivalent of `apply`'s same-count branch.
        ///
        /// `isStreaming`: when true, the row is the actively-growing trailing row
        /// of a live stream → render the **links-only** tier (nil `embedInfo`) so
        /// a half-typed `![[source:…` never instantiates a broken iframe/player
        /// that churns per token. When false, the row is being *re-finalized*
        /// (a new event landed = turn boundary) → render the full context.
        private func replaceLastRow(_ event: AgentEvent, at index: Int, isStreaming: Bool, allEvents: [AgentEvent], context: WikiRenderContext? = nil) {
            let ts = index < timestamps.count ? timestamps[index] : nil
            let html = Self.rowHTML(for: event, style: style, context: context, isFinal: !isStreaming, timestamp: ts, allEvents: allEvents, allTimestamps: timestamps, index: index)
            guard let data = try? JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]),
                  let jsonString = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("replaceLastRow(\(jsonString))", completionHandler: nil)
        }

        // MARK: - Copy button (issue #285)

        /// Receives the raw markdown text from the JS click listener and writes it
        /// to the system pasteboard. Called on the main thread by WebKit.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == ChatWebView.copyMessageName,
                  let text = message.body as? String
            else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        // MARK: - Row rendering

        private static func rowHTML(for event: AgentEvent, style: VisualStyle, context: WikiRenderContext?, isFinal: Bool, timestamp: Date? = nil, allEvents: [AgentEvent] = [], allTimestamps: [Date?] = [], index: Int = -1) -> String {
            switch style {
            case .activityFeed: feedRowHTML(for: event, context: context, isFinal: isFinal)
            case .chat: chatRowHTML(for: event, context: context, isFinal: isFinal, timestamp: timestamp, allEvents: allEvents, allTimestamps: allTimestamps, index: index)
            }
        }

        /// Render assistant/result markdown with the shared footnote + wiki-link
        /// pre-pass. With a `WikiRenderContext` (Phase A.2), it threads the
        /// context's pure `isResolved`/`embedInfo`/`displayName`/`pinnedExtractionID`
        /// closures into `ReaderMarkdown.prepared` — so chat transcripts render
        /// source references exactly as the reader does: healed display names,
        /// `&pin=` URLs, ghost styling for broken links, and inline `![[source:…]]`
        /// embeds. **Two-tier:** while a row is still streaming (`isFinal == false`),
        /// `embedInfo` is forced to nil so a half-typed `![[source:…` never
        /// instantiates a broken iframe/player that churns per token; the row
        /// re-renders with embeds once it finalizes.
        ///
        /// nil context keeps the historical constant-`true` resolution (used by
        /// `AgentQueueView`'s internals feed, where ghost styling is noise).
        /// User text is intentionally NOT run through this — a user typing
        /// `[[Foo]]` is not a link. `internal` so the linkify behavior is
        /// unit-testable.
        static func renderedMarkdown(_ text: String, context: WikiRenderContext? = nil, isFinal: Bool = true) -> String {
            if let context {
                // Two-tier: a non-final (still-streaming) row renders links only —
                // pass nil embedInfo so a half-typed `![[source:…` can't render a
                // broken iframe/player. The row re-renders with embeds on finalize.
                let embedInfo = isFinal ? context.embedInfo : nil
                let prepared = ReaderMarkdown.prepared(text,
                    isResolved: context.isResolved,
                    embedInfo: embedInfo,
                    displayName: context.displayName,
                    pinnedExtractionID: context.pinnedExtractionID)
                return MarkdownHTMLRenderer.render(prepared)
            }
            return MarkdownHTMLRenderer.render(ReaderMarkdown.prepared(text) { _, _ in true })
        }

        static func feedRowHTML(for event: AgentEvent, context: WikiRenderContext? = nil, isFinal: Bool = true) -> String {
            switch event {
            case .userText(let text):
                return """
                <div class="row row-user"><div class="row-label">You</div>\
                <div class="row-body">\(renderedMarkdown(text, context: context, isFinal: isFinal))</div></div>
                """
            case .systemInit(let model):
                return "<div class=\"row row-meta\">Started · \(escape(model))</div>"
            case .assistantText(let text):
                return "<div class=\"row row-assistant\">\(renderedMarkdown(text, context: context, isFinal: isFinal))</div>"
            case .thinking(let text):
                return thinkingRowHTML(text: text, context: context, isFinal: isFinal)
            case .toolUse(let name, let summary):
                return feedToolRowHTML(name: name, summary: summary, isError: false)
            case .toolResult(let isError, let summary):
                let body = summary.isEmpty ? (isError ? "(error)" : "(ok)") : summary
                return feedToolRowHTML(name: nil, summary: body, isError: isError)
            case .subagent(let subagentType, let description, let isCompletion):
                let verb = isCompletion ? "digested" : "reading"
                let descHTML = description.isEmpty ? "" : " — \(escape(description))"
                return """
                <div class="row row-subagent\(isCompletion ? " is-complete" : "")">\
                <span class="row-subagent-type">\(escape(subagentType))</span> \(verb)\(descHTML)</div>
                """
            case .result(let isError, let text):
                let label = isError ? "Failed" : "Result"
                let bodyHTML = text.isEmpty ? "" : renderedMarkdown(text, context: context, isFinal: isFinal)
                return """
                <div class="row row-result\(isError ? " is-error" : "")"><div class="row-label">\(label)</div>\(bodyHTML)</div>
                """
            case .messageStop, .assistantTextDelta, .thinkingDelta:
                return ""  // internal — not rendered (deltas are merged upstream)
            case .turnFailed(let reason):
                return turnFailedBannerHTML(reason: reason)
            case .raw(let line):
                return "<pre class=\"row row-raw\">\(escape(line))</pre>"
            }
        }

        /// The Query page chat look: a right-aligned capsule for the user, plain
        /// prose for the assistant (matching `QueryMessageBubble`'s prior
        /// SwiftUI rendering), no row labels. Tool calls render as a concise,
        /// muted one-line progress indicator (issue #173) — independent of the
        /// "Show internals" toggle, which still gates the full raw feed.
        static func chatRowHTML(for event: AgentEvent, context: WikiRenderContext? = nil, isFinal: Bool = true, timestamp: Date? = nil, allEvents: [AgentEvent] = [], allTimestamps: [Date?] = [], index: Int = -1) -> String {
            switch event {
            case .userText(let text):
                // Run user text through the markdown renderer so prepended
                // attachment refs ([[source:Name]]) render as clickable
                // wikilinks, not raw escaped text (issue #385).
                return """
                <div class="row chat-row chat-user"><div class="bubble">\(renderedMarkdown(text, context: context, isFinal: isFinal))</div></div>
                """
            case .assistantText(let text):
                return assistantBubbleHTML(text: text, context: context, isFinal: isFinal, timestamp: timestamp, allEvents: allEvents, allTimestamps: allTimestamps, index: index)
            case .thinking(let text):
                return thinkingRowHTML(text: text, context: context, isFinal: isFinal)
            case .result(_, let text):
                guard !text.isEmpty else { return "" }
                return assistantBubbleHTML(text: text, context: context, isFinal: isFinal, timestamp: timestamp, allEvents: allEvents, allTimestamps: allTimestamps, index: index)
            case .toolUse(let name, let summary):
                return chatToolRowHTML(name: name, summary: summary, isError: false)
            case .toolResult(let isError, let summary):
                // Only error results reach a chat-styled transcript (successes are
                // filtered out upstream in `ChatTranscriptView.visibleEvents`).
                guard isError else { return "" }
                return chatToolRowHTML(name: nil, summary: summary, isError: true)
            case .systemInit, .subagent, .messageStop, .raw, .assistantTextDelta, .thinkingDelta:
                return ""
            case .turnFailed(let reason):
                return turnFailedBannerHTML(reason: reason)
            }
        }

        /// Inline SVG for the copy button (lucide `Copy` icon, inner `currentColor`
        /// so CSS controls the tint). Duplicated as a JS string in `shellHTML`
        /// so the click handler can swap between copy↔check without a round-trip.
        private static let copyIconSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>"#

        /// Inline SVG for the post-copy checkmark (lucide `Check` icon) — shown for
        /// ~1.5 s to confirm the clipboard write landed.
        private static let checkIconSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>"#

        /// Format a duration (seconds) as a compact string: "47s", "2m 12s",
        /// "1h 5m". Mirrors Paseo's `formatDuration` (utils/time.ts).
        static func formatDuration(_ seconds: TimeInterval) -> String {
            let s = max(0, Int(seconds.rounded(.down)))
            if s < 60 { return "\(s)s" }
            let m = s / 60
            if m < 60 {
                let rem = s % 60
                return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
            }
            let h = m / 60
            let remMin = m % 60
            return remMin == 0 ? "\(h)h" : "\(h)h \(remMin)m"
        }

        /// Format a timestamp for the hover-reveal label — same-day shows just
        /// the time; older shows the date + time. Mirrors Paseo's
        /// `formatMessageTimestamp` (utils/time.ts).
        static func formatTimestamp(_ date: Date, now: Date = Date()) -> String {
            let timeFmt = DateFormatter()
            timeFmt.timeStyle = .short
            let timeStr = timeFmt.string(from: date)
            guard Calendar.current.isDate(date, inSameDayAs: now) else {
                let dateFmt = DateFormatter()
                dateFmt.dateStyle = .medium
                return "\(dateFmt.string(from: date)), \(timeStr)"
            }
            return timeStr
        }

        /// Compute the "Worked for Xs" duration for a row: the gap between
        /// this row's timestamp and the previous non-nil timestamp in the
        /// parallel array. If there's no predecessor, returns nil.
        private static func workDuration(at index: Int, timestamps: [Date?]) -> TimeInterval? {
            guard index < timestamps.count, let ts = timestamps[index] else { return nil }
            for i in stride(from: min(index - 1, timestamps.count - 1), through: 0, by: -1) {
                if let prev = timestamps[i] {
                    return ts.timeIntervalSince(prev)
                }
            }
            return nil
        }

        /// A chat-style assistant bubble (markdown prose + a hover-revealed copy
        /// icon button). Shared by `.assistantText` and `.result` rows (issue #285).
        /// The button's `data-copy` attribute carries the **raw markdown** (HTML-
        /// attribute-escaped) — not the rendered HTML — so the clipboard gets the
        /// plain text the user would have drag-selected. The icon swaps to a green
        /// checkmark for ~1.5 s after clicking (mirrors Paseo's `TurnCopyButton`).
        ///
        /// When `timestamp` is non-nil, a "Worked for Xs" footer is appended below
        /// the prose. On hover, the duration swaps to the completion timestamp
        /// (CSS-only, no JS) — mirroring Paseo's `AssistantTurnFooter`.
        private static func assistantBubbleHTML(text: String, context: WikiRenderContext?, isFinal: Bool, timestamp: Date? = nil, allEvents: [AgentEvent] = [], allTimestamps: [Date?] = [], index: Int = -1) -> String {
            var html = """
            <div class="row chat-row chat-assistant"><div class="bubble">\
            \(renderedMarkdown(text, context: context, isFinal: isFinal))</div>
            """

            // Footer action bar: sits on its own line directly beneath the bubble
            // so it reads as attached to the response. Holds the copy button and,
            // when a timestamp is available, the "Worked for Xs" label (which
            // hover-swaps to the completion timestamp).
            var metaHTML = ""
            if let ts = timestamp {
                let duration = Self.workDuration(at: index, timestamps: allTimestamps)
                let durationLabel = duration.map { "Worked for \(Self.formatDuration($0))" } ?? ""
                let timestampLabel = Self.formatTimestamp(ts)
                // The meta: a sizer (hidden, reserves width) + the visible
                // duration label + the timestamp (hidden by default). On hover,
                // the duration fades out and the timestamp fades in — pure CSS,
                // width stays stable (sizer reserves the wider of the two).
                let durationHTML = durationLabel.isEmpty ? "" : #"<span class="turn-duration">\#(escape(durationLabel))</span>"#
                metaHTML = #"<span class="turn-meta"><span class="turn-sizer">\#(escape(timestampLabel))</span>\#(durationHTML)<span class="turn-timestamp">\#(escape(timestampLabel))</span></span>"#
            }
            html += #"<div class="turn-footer"><button class="copy-btn" type="button" data-copy="\#(htmlAttributeEscape(text))" aria-label="Copy">\#(Self.copyIconSVG)</button>\#(metaHTML)</div>"#

            html += "</div>"
            return html
        }

        /// A single muted, left-aligned progress line for a tool call — the
        /// lightweight in-transcript indicator (issue #173). Not a chat bubble:
        /// it reads like a status line, so it stays subordinate to the prose.
        private static func chatToolRowHTML(name: String?, summary: String, isError: Bool) -> String {
            let nameHTML = name.map { "<span class=\"chat-tool-name\">\(escape($0))</span>" } ?? ""
            let body = summary.isEmpty ? (isError ? "(error)" : "") : summary
            let summaryHTML = body.isEmpty ? "" : "<span class=\"chat-tool-summary\">\(escape(body))</span>"
            // Expandable tool row (issue #381): a <details> element so the user
            // can click to reveal the full summary. Only adds the disclosure if
            // there's content to expand into; otherwise renders as before.
            if body.isEmpty {
                return """
                <div class="row chat-row chat-tool\(isError ? " is-error" : "")">\
                \(nameHTML)\(summaryHTML)</div>
                """
            }
            return """
            <details class="row chat-row chat-tool\(isError ? " is-error" : "")">\
            <summary>\(nameHTML)\(summaryHTML)</summary>\
            <pre class="chat-tool-detail\">\(escape(body))</pre></details>
            """
        }

        /// A styled amber banner for a turn failure (timeout, ceiling, agent
        /// error). Distinct from `.row-raw` (plain `<pre>`) and `.row-result`
        /// (final answer): this is a scannable inline banner with an icon and
        /// plain-English reason. (#422)
        private static func turnFailedBannerHTML(reason: TurnFailureReason) -> String {
            """
            <div class="row row-turn-failed">\
            <span class="row-turn-failed-icon">⚠︎</span>\
            <div class="row-turn-failed-body">\
            <strong>\(escape(reason.label))</strong> \(escape(reason.description))</div></div>
            """
        }

        /// An activity-feed tool row: a collapsible `<details>` box showing the
        /// tool name + summary in the header (collapsed), and the full text in
        /// an expandable body. Used by both `.toolUse` and `.toolResult` in
        /// `feedRowHTML` (the inspector/internals view) - issue #391.
        /// `name` is nil for tool results; `summary` carries the command/output text.
        private static func feedToolRowHTML(name: String?, summary: String, isError: Bool) -> String {
            let nameHTML = name.map { "<span class=\"row-tool-name\">\(escape($0))</span>" } ?? ""
            if summary.isEmpty {
                return "<div class=\"row row-tool\(isError ? " is-error" : "")\">\(nameHTML)</div>"
            }
            // The collapsed header shows ONLY a truncated first line — putting
            // the whole summary in <summary> renders the full multi-line text
            // even while "collapsed", with the expandable body a duplicate.
            let firstLine = String(summary.split(separator: "\n", maxSplits: 1,
                                                 omittingEmptySubsequences: false).first ?? "")
            let truncated = summary.contains("\n") || firstLine.count > 120
            let preview = firstLine.count > 120
                ? String(firstLine.prefix(120)) + "\u{2026}"
                : firstLine + (summary.contains("\n") ? " \u{2026}" : "")
            let previewHTML = "<span class=\"row-tool-summary\">\(escape(preview))</span>"
            // Short single-line summaries have nothing to expand into — render
            // a flat row instead of a pointless disclosure triangle.
            guard truncated else {
                return "<div class=\"row row-tool\(isError ? " is-error" : "")\">\(nameHTML)\(previewHTML)</div>"
            }
            return """
            <details class="row row-tool collapsible\(isError ? " is-error" : "")">\
            <summary>\(nameHTML)\(previewHTML)</summary>\
            <pre class="collapsible-detail">\(escape(summary))</pre></details>
            """
        }

        /// A collapsible, dimmed/italic "thinking" box - the agent's
        /// chain-of-thought reasoning (issue #391). Uses a `<details>` element
        /// so the reasoning text is hidden by default and expanded on click.
        /// The summary shows a "Thinking" label + a truncated preview; the body
        /// renders the full text (markdown, same as assistant prose).
        private static func thinkingRowHTML(text: String, context: WikiRenderContext?, isFinal: Bool) -> String {
            let preview = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let previewShort = preview.count > 80 ? String(preview.prefix(80)) + "\u{2026}" : preview
            let bodyHTML = renderedMarkdown(text, context: context, isFinal: isFinal)
            return """
            <details class="row row-thinking collapsible">\
            <summary><span class="row-thinking-label">Thinking</span> \
            <span class="row-thinking-preview">\(escape(previewShort))</span></summary>\
            <div class="row-thinking-body">\(bodyHTML)</div></details>
            """
        }

        private static func escape(_ s: String) -> String {
            HTMLEntities.escapeHTML(s)
        }

        /// JavaScript that highlights the first occurrence of `quote` in the
        /// transcript and scrolls it into view — mirrors the reader's
        /// `WikiReaderView.applyFind` (clear prior `mark.sdwhl`, `window.find`
        /// from the document top, wrap the selection, `scrollIntoView`). The
        /// transcript is one document, so `window.find` lands on the first match
        /// — the same message `ChatQuoteResolver.messageIndex` identifies.
        static func highlightAndScrollJS(quote: String) -> String {
            let q = jsEscape(quote)
            return """
            (function(q){
              document.querySelectorAll("mark.sdwhl").forEach(function(m){
                var p=m.parentNode; while(m.firstChild) p.insertBefore(m.firstChild,m);
                p.removeChild(m); p.normalize();
              });
              var sel=window.getSelection();
              sel.removeAllRanges();
              var body=document.body;
              if(body){
                var r0=document.createRange();
                r0.setStart(body,0); r0.collapse(true);
                sel.addRange(r0);
              }
              window.find(q,false,false,false,false);
              if(sel.rangeCount>0 && !sel.isCollapsed){
                var r=sel.getRangeAt(0); var mark=document.createElement("mark");
                mark.className="sdwhl";
                try{ r.surroundContents(mark); }catch(e){
                  mark.appendChild(document.createTextNode(q));
                  r.insertNode(mark);
                }
                var mk=document.querySelector("mark.sdwhl");
                if(mk){ mk.scrollIntoView({block:"center"}); }
              }
            })("\(q)");
            """
        }

        /// Escape a string for safe embedding in a double-quoted JS string
        /// literal. Mirrors `WikiReaderRep.jsString`.
        private static func jsEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "\\r")
        }

        private static func escapePreservingBreaks(_ s: String) -> String {
            escape(s).replacingOccurrences(of: "\n", with: "<br>")
        }

        /// Escapes a string for safe embedding in a double-quoted HTML attribute
        /// value. The DOM decodes entities when reading `.dataset`, so JS receives
        /// the original text verbatim — no JSON round-trip needed.
        private static func htmlAttributeEscape(_ s: String) -> String {
            escape(s).replacingOccurrences(of: "\"", with: "&quot;")
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
            /* Right-side padding keeps content clear of the WebView's scrollbar
               so the right margin matches the left (which has no scrollbar). */
            padding: 10px 12px 10px 0; -webkit-font-smoothing: antialiased;
            /* Never let content exceed the web view's width — long tokens/URLs
               in list items and paragraphs wrap instead of clipping off the
               right edge or pushing list markers off the left. */
            overflow-wrap: break-word; word-wrap: break-word;
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
          .row-tool.is-error { color: #ff453a; }
          /* Collapsible rows (issue #391): <details> elements for tool calls
             + thinking. The summary is the visible header; the body expands
             on click. Shared styling, distinct from chat-tool's older CSS. */
          .collapsible > summary { list-style: none; cursor: pointer; }
          .collapsible > summary::-webkit-details-marker { display: none; }
          .collapsible[open] > summary::before {
            content: "\\25BE "; opacity: 0.5;
          }
          .collapsible:not([open]) > summary::before {
            content: "\\25B8 "; opacity: 0.5;
          }
          .collapsible-detail {
            margin: 4px 0 0; padding: 6px 8px; font-size: 11px;
            background: var(--code-bg); border-radius: 4px;
            white-space: pre-wrap; word-break: break-word;
            max-height: 300px; overflow-y: auto;
          }
          /* Thinking rows: dimmed + italic, visually subordinate to the
             conversation (issue #391). */
          .row-thinking { font-size: 11.5px; color: var(--muted); margin: 0 0 8px; }
          .row-thinking > summary { font-style: italic; }
          .row-thinking-label { font-weight: 600; color: var(--muted); }
          .row-thinking-preview { opacity: 0.7; }
          .row-thinking-body {
            margin: 4px 0 0; padding: 6px 10px; font-style: italic;
            font-size: 11.5px; color: var(--muted);
            background: var(--code-bg); border-radius: 4px;
            border-left: 2px solid var(--border);
            max-height: 400px; overflow-y: auto;
          }
          .row-result .row-label { font-weight: 600; font-size: 12px; color: var(--text); }
          .row-result.is-error .row-label { color: #ff453a; }
          .row-raw {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 11px; color: var(--muted); margin: 0 0 8px;
            white-space: pre-wrap; word-break: break-word;
          }
          .row-turn-failed {
            display: flex; align-items: baseline; gap: 6px;
            margin: 0 0 14px; padding: 8px 12px;
            background: rgba(255, 159, 10, 0.12);
            border-left: 3px solid #ff9f0a;
            border-radius: 6px; font-size: 12px; color: var(--text);
          }
          .row-turn-failed-icon { font-size: 14px; line-height: 1; }
          .row-turn-failed-body strong { font-weight: 600; color: #ff9f0a; }
          .chat-row { display: flex; margin: 0 0 14px; }
          .chat-user { justify-content: flex-end; }
          .chat-assistant { justify-content: flex-start; flex-direction: column; }
          .chat-user .bubble { max-width: min(760px, 86%); }
          .chat-user .bubble {
            background: var(--code-bg); border-radius: 14px;
            padding: 11px 16px; white-space: pre-wrap; font-size: 13.5px;
          }
          .chat-assistant .bubble { position: relative; }
          /* Footer action bar beneath the response: copy button + "Worked for Xs"
             label share one line, left-aligned under the bubble so they read as
             attached to it. */
          .turn-footer {
            display: flex; align-items: center; gap: 4px;
            margin-top: 4px; margin-left: 6px; min-height: 20px;
          }
          .copy-btn {
            display: flex; align-items: center; justify-content: center;
            opacity: 0; transition: opacity 0.15s ease, color 0.15s ease;
            -webkit-appearance: none; appearance: none;
            background: none; border: none; border-radius: 5px;
            padding: 3px; cursor: pointer;
            color: var(--muted);
          }
          .chat-assistant:hover .copy-btn { opacity: 0.55; }
          .copy-btn:hover { opacity: 1; color: var(--text); background: var(--code-bg); }
          .copy-btn.copied { opacity: 1; color: #34c759; }
          .copy-btn svg { display: block; }
          /* "Worked for Xs" with hover-swap to timestamp. Mirrors Paseo's
             AssistantTurnFooter — a sizer reserves width so the label doesn't
             shift when swapping. */
          .turn-meta {
            position: relative; display: inline-block;
            min-height: 16px;
          }
          .turn-sizer {
            visibility: hidden; opacity: 0;
            font-size: 11px; color: var(--muted);
            white-space: nowrap; height: 0; display: block;
          }
          .turn-duration, .turn-timestamp {
            position: absolute; top: 0; left: 0;
            font-size: 11px; color: var(--muted);
            white-space: nowrap; transition: opacity 0.15s ease;
          }
          .turn-duration { opacity: 0.6; }
          .turn-timestamp { opacity: 0; }
          .chat-assistant:hover .turn-duration { opacity: 0; }
          .chat-assistant:hover .turn-timestamp { opacity: 0.7; }
          .chat-tool {
            justify-content: flex-start; align-items: baseline;
            gap: 6px; font-size: 11.5px; color: var(--muted);
            padding: 1px 2px;
          }
          .chat-tool-name {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-weight: 600; color: var(--text);
          }
          .chat-tool-summary {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          .chat-tool.is-error { color: #ff453a; }
          .chat-tool.is-error .chat-tool-name { color: #ff453a; }
          .chat-tool > summary { list-style: none; cursor: pointer; }
          .chat-tool > summary::-webkit-details-marker { display: none; }
          .chat-tool[open] > summary .chat-tool-summary::before {
            content: "▾ "; opacity: 0.5;
          }
          .chat-tool:not([open]) > summary .chat-tool-summary::before {
            content: "▸ "; opacity: 0.5;
          }
          .chat-tool-detail {
            margin: 4px 0 0; padding: 6px 8px; font-size: 11px;
            background: var(--code-bg); border-radius: 4px;
            white-space: pre-wrap; word-break: break-word;
            max-height: 200px; overflow-y: auto;
          }
          p { margin: 0 0 0.6em; }
          p:last-child { margin-bottom: 0; }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 0.7em 0 0.3em; }
          h1 { font-size: 1.25em; } h2 { font-size: 1.15em; }
          h3 { font-size: 1.05em; } h4, h5, h6 { font-size: 1em; }
          strong { font-weight: 600; }
          a { color: -webkit-link; }
          mark.sdwhl { background: rgba(255, 213, 79, 0.8); border-radius: 2px; }
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
          /* Slightly larger left padding so multi-digit markers ("10.") sit
             fully inside the content box and never clip off the left edge. */
          ul, ol { padding-left: 1.8em; margin: 0 0 0.6em; }
          li { margin: 0.1em 0; overflow-wrap: break-word; word-wrap: break-word; }
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
          function replaceLastRow(html) {
            if (document.body.lastElementChild) {
              document.body.lastElementChild.outerHTML = html;
            } else {
              document.body.insertAdjacentHTML('beforeend', html);
            }
            window.scrollTo(0, document.body.scrollHeight);
          }
          // Delegated click handler for the per-bubble copy icon (issue #285).
          // Works on dynamically-appended rows since it's on `document`. Posts the
          // raw markdown text (from `data-copy`) to the Swift message handler, then
          // swaps the icon to a green checkmark for ~1.5 s (mirrors Paseo's
          // TurnCopyButton Copy↔Check swap).
          var copyIconSVG = '<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>';
          var checkIconSVG = '<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>';
          document.addEventListener('click', function(e) {
            var btn = e.target.closest && e.target.closest('.copy-btn');
            if (!btn) return;
            e.preventDefault();
            var text = btn.dataset.copy || '';
            try {
              window.webkit.messageHandlers.copyText.postMessage(text);
            } catch (err) { /* handler not registered — no-op */ }
            btn.innerHTML = checkIconSVG;
            btn.classList.add('copied');
            setTimeout(function() {
              btn.innerHTML = copyIconSVG;
              btn.classList.remove('copied');
            }, 1500);
          });
          document.addEventListener('dblclick', function(e) {
            var summary = e.target.closest && e.target.closest('summary');
            if (!summary) return;
            var details = summary.closest('details');
            if (!details) return;
            details.open = !details.open;
          });
        </script>
        </body></html>
        """
    }
}
