import AppKit
import WikiFSEngine
import SwiftUI
import WebKit
import WikiFSCore

extension ChatDisplayRowID {
    /// Prefixes make the DOM namespace explicit even where raw durable IDs
    /// happen to share the same string representation.
    var domValue: String {
        switch self {
        case .message(let id): "message-\(id.rawValue)"
        case .toolCall(let id): "tool-\(id.rawValue)"
        case .notice(let id): "notice-\(id.rawValue)"
        case .failure(let id): "failure-\(id.rawValue)"
        }
    }

    init?(domValue: String) {
        if domValue.hasPrefix("message-") {
            self = .message(ChatMessageID(rawValue: String(domValue.dropFirst("message-".count))))
        } else if domValue.hasPrefix("tool-") {
            self = .toolCall(ToolCallID(rawValue: String(domValue.dropFirst("tool-".count))))
        } else if domValue.hasPrefix("notice-") {
            self = .notice(ChatTranscriptNoticeID(rawValue: String(domValue.dropFirst("notice-".count))))
        } else if domValue.hasPrefix("failure-") {
            self = .failure(ChatTranscriptFailureID(rawValue: String(domValue.dropFirst("failure-".count))))
        } else {
            return nil
        }
    }
}

/// Compatibility filtering belongs to the legacy activity-feed renderer, not
/// the typed chat transcript adapter. Retaining it here preserves the separate
/// activity/history surface without letting chat presentation use event arrays.
extension [AgentEvent] {
    var transcriptVisibleIndices: [Int] {
        indices.filter { self[$0].isVisibleInTranscript(in: self) }
    }

    var transcriptVisible: [AgentEvent] {
        transcriptVisibleIndices.map { self[$0] }
    }
}

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
/// Activity-feed `events` are expected to only grow in length, or have their LAST element mutated
/// in place (a streamed text delta merged into an in-progress `.assistantText`,
/// issue #121), except for an explicit reset to `[]` (`AgentLauncher.events`'s
/// contract): new events are inserted into the live DOM via `appendRows`, and an
/// in-place growth of the last row is patched via `replaceLastRow`, rather than a
/// full reload — so an in-progress text selection survives a streaming run. A
/// count *decrease* (a reset), a `showsInternals` change (which changes which
/// underlying activity events are visible), or a `transcriptID` change (the events now
/// describe a different conversation entirely) forces a full rebuild.
///
/// A versioned request to scroll the chat transcript to a user turn. Mirrors the
/// reader's anchor-version pattern: `version` bumps to signal a new request;
/// `rowID` targets the durable prompt row without deriving identity from a
/// rendered index. Consumed in `ChatWebView.updateNSView`.
struct ChatWebScrollRequest: Equatable {
    let version: Int
    let rowID: ChatDisplayRowID
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

/// Identity of the transcript a `ChatWebView` renders — the key its
/// incremental differ uses to decide whether the DOM it already built belongs
/// to the same conversation as the incoming `events`.
///
/// Namespaced by case rather than a bare `String`, so an id from one space can
/// never compare equal to an id from another: chat rows and queue items are
/// both ULIDs, and a raw-string key would silently treat a collision as "same
/// transcript" — precisely the failure this type exists to prevent.
enum TranscriptID: Hashable, Sendable {
    /// A chat's persisted row (`ChatDetailView` → `ChatTranscriptView`). The
    /// draft composer (`chatID == nil`) has no transcript to render, so there
    /// is deliberately no draft case.
    case chat(ChatID)
    /// A queue item's activity feed (`ActivityWindowView`).
    case queueItem(QueueItem.ID)
}

struct ChatWebView: NSViewRepresentable {
    /// The legacy activity-feed input. Chat transcripts use `chatRows` so the
    /// presentation layer does not discard durable row identity.
    let events: [AgentEvent]
    let chatRows: [ChatDisplayRow]?
    /// Identity of the transcript these `events` belong to (a chat ULID, a
    /// queue item id, …). The coordinator renders **incrementally** — it
    /// appends only `events[renderedCount...]` — which is only sound while
    /// successive `events` arrays are successive states of the SAME transcript.
    ///
    /// SwiftUI reuses an `NSViewRepresentable`'s view + coordinator whenever
    /// structural identity is unchanged, and switching between two chat tabs
    /// (or two queue items) does not change structural identity — the branch of
    /// the enclosing `switch` is the same, only the associated value differs.
    /// Without this key the differ would splice transcript B's tail onto
    /// transcript A's DOM (`count > renderedCount` → append) or patch only the
    /// last row (`count == renderedCount`), leaving the previous chat's
    /// messages on screen and freezing subsequent streaming appends.
    ///
    /// A change forces a full rebuild. `nil` (the default) opts out — for
    /// call sites that render exactly one transcript for the view's lifetime.
    var transcriptID: TranscriptID? = nil
    /// A value that, when it changes, forces a full rebuild rather than an
    /// append — for callers whose event→visible-row filtering can change
    /// retroactively (e.g. an activity-feed filtering toggle).
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
    var scrollRequest: ChatWebScrollRequest? = nil
    /// Versioned request to highlight + scroll to a `[[chat:Title#"quote"]]`
    /// passage (issue #281). `nil` (default) never highlights; consumed in
    /// `updateNSView` (re-click on a loaded transcript) and `didFinish` (fresh
    /// load). The coordinator stashes it and applies once rows are rendered.
    var quoteAnchor: ChatHighlightRequest? = nil

    /// Typed UI callback used only by the chat transcript. The activity-feed
    /// API retains its existing raw navigation closure for compatibility.
    var onChatIntent: ((ChatTranscriptIntent) -> Void)? = nil

    /// Name of the `WKScriptMessage` channel the per-bubble "Copy" button posts
    /// to (issue #285). The JS click listener calls
    /// `window.webkit.messageHandlers.copyText.postMessage(text)`; the coordinator
    /// writes `text` to `NSPasteboard`.
    static let copyMessageName = "copyText"
    static let followMessageName = "chatFollowState"

    init(
        events: [AgentEvent],
        transcriptID: TranscriptID? = nil,
        showsInternals: Bool = false,
        onWikiLink: ((URL, Bool) -> Void)? = nil,
        renderContext: (() -> WikiRenderContext?)? = nil,
        blobStore: WikiStoreModel? = nil,
        zoom: Double = Double(ZoomScale.defaultScale),
        scrollRequest: ChatWebScrollRequest? = nil,
        quoteAnchor: ChatHighlightRequest? = nil
    ) {
        self.events = events
        self.chatRows = nil
        self.transcriptID = transcriptID
        self.showsInternals = showsInternals
        self.onWikiLink = onWikiLink
        self.renderContext = renderContext
        self.blobStore = blobStore
        self.zoom = zoom
        self.scrollRequest = scrollRequest
        self.quoteAnchor = quoteAnchor
    }

    init(
        chatRows: [ChatDisplayRow],
        transcriptID: TranscriptID?,
        onChatIntent: @escaping (ChatTranscriptIntent) -> Void,
        renderContext: (() -> WikiRenderContext?)? = nil,
        blobStore: WikiStoreModel? = nil,
        zoom: Double = Double(ZoomScale.defaultScale),
        scrollRequest: ChatWebScrollRequest? = nil,
        quoteAnchor: ChatHighlightRequest? = nil
    ) {
        self.events = []
        self.chatRows = chatRows
        self.transcriptID = transcriptID
        self.onWikiLink = nil
        self.renderContext = renderContext
        self.blobStore = blobStore
        self.zoom = zoom
        self.scrollRequest = scrollRequest
        self.quoteAnchor = quoteAnchor
        self.onChatIntent = onChatIntent
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
        cc.add(context.coordinator, name: Self.followMessageName)
        config.userContentController = cc
        let blobHandler = BlobSchemeHandler(store: blobStore)
        config.setURLSchemeHandler(blobHandler, forURLScheme: BlobSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.pageZoom = zoom
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.onChatIntent = onChatIntent
        context.coordinator.renderContext = renderContext
        if let chatRows {
            context.coordinator.reload(chatRows: chatRows, transcriptID: transcriptID)
        } else {
            context.coordinator.reload(events: events, showsInternals: showsInternals,
                                       transcriptID: transcriptID)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom
        context.coordinator.onWikiLink = onWikiLink
        context.coordinator.onChatIntent = onChatIntent
        context.coordinator.renderContext = renderContext
        // Keep the blob handler's store fresh (a wiki switch swaps the store).
        if let handler = webView.configuration.urlSchemeHandler(forURLScheme: BlobSchemeHandler.scheme) as? BlobSchemeHandler {
            handler.store = blobStore
        }
        if let chatRows {
            context.coordinator.apply(chatRows: chatRows, transcriptID: transcriptID)
        } else {
            context.coordinator.apply(events: events, showsInternals: showsInternals,
                                      transcriptID: transcriptID)
        }
        // Outline click → scroll the i-th user bubble into view. Only fires when
        // the version advances, so unrelated re-renders (streaming) don't re-scroll.
        if let req = scrollRequest, req.version != context.coordinator.appliedScrollVersion {
            context.coordinator.appliedScrollVersion = req.version
            let rowID = ChatWebView.Coordinator.jsEscape(req.rowID.domValue)
            let js = "(function(){var el=document.querySelector('[data-row-id=\\\"\(rowID)\\\"]');if(el){el.scrollIntoView({block:'start'});}})()"
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        /// Routes a clicked `wiki://` link out to the view's `onWikiLink`
        /// closure (built where the store lives). Refreshed each update.
        var onWikiLink: ((URL, Bool) -> Void)?
        var onChatIntent: ((ChatTranscriptIntent) -> Void)?
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
        /// The `transcriptID` the currently-rendered DOM was built from. When
        /// the incoming id differs, the incremental differ's anchors
        /// (`renderedCount`/`renderedEvents`/`renderedLastEvent`) describe a
        /// *different* transcript and must not be used — see
        /// `ChatWebView.transcriptID`.
        private var renderedTranscriptID: TranscriptID?
        private var pendingTranscriptID: TranscriptID?
        private var isLoaded = false
        private var pendingEvents: [AgentEvent] = []
        /// The last event actually rendered, so `apply` can detect "no new row, but
        /// `AgentLauncher` grew the last one in place" (a streamed `.assistantText`
        /// delta merge, issue #121) and patch that row instead of no-op'ing.
        private var renderedLastEvent: AgentEvent?
        /// The full event list as last seen, used to compute `isFinal` (a row is
        /// non-final only when it is the LAST row of a still-live event stream —
        /// i.e. it may still grow via `replaceLastRow`). Captured in `apply`.
        private var renderedEvents: [AgentEvent] = []
        private var rendersTypedChatRows = false
        private var followState: ChatTranscriptFollowState = .following
        private var pendingChatReloadAcknowledgement: (@MainActor (ChatTranscriptRenderAcknowledgement) -> Void)?
        private lazy var chatRenderExecutor = ChatTranscriptRenderExecutor(
            mutate: { [weak self] command, revision, acknowledge in
                guard let self else { return }
                self.performChatRenderMutation(command, revision: revision, acknowledge: acknowledge)
            },
            reportAnomaly: { anomaly in
                DebugLog.store("chat transcript renderer anomaly: \(anomaly)")
            }
        )

        /// Resolve the provider once per render pass on the main actor. Returns
        /// the current `WikiRenderContext` (or nil → constant-true behavior).
        private func currentContext() -> WikiRenderContext? { renderContext?() }

        /// Pure predicate for "this render pass cannot append/patch — rebuild
        /// the whole document". Extracted so the three rebuild triggers are
        /// testable without a WebKit view tree.
        ///
        /// - A `transcriptID` change means the DOM belongs to a different
        ///   transcript entirely (chat tab switch, queue item switch).
        /// - A `showsInternals` change retroactively changes which events are
        ///   visible, so previously-rendered rows are wrong.
        /// - A count *decrease* is the reset contract (`events = []`).
        ///
        /// `nonisolated`: a pure predicate over value types, so tests can call
        /// it without hopping to the main actor (same discipline as
        /// `ChatTranscriptRenderingInput`).
        nonisolated static func needsFullReload(
            transcriptID: TranscriptID?, renderedTranscriptID: TranscriptID?,
            showsInternals: Bool, renderedShowsInternals: Bool?,
            eventCount: Int, renderedCount: Int
        ) -> Bool {
            if transcriptID != renderedTranscriptID { return true }
            if showsInternals != renderedShowsInternals { return true }
            return eventCount < renderedCount
        }

        func reload(events: [AgentEvent], showsInternals: Bool,
                    transcriptID: TranscriptID? = nil) {
            rendersTypedChatRows = false
            renderedCount = 0
            renderedShowsInternals = showsInternals
            renderedTranscriptID = transcriptID
            renderedLastEvent = nil
            renderedEvents = events
            isLoaded = false
            pendingEvents = events
            pendingTranscriptID = transcriptID
            webView?.loadHTMLString(Self.shellHTML, baseURL: URL(string: "about:blank"))
        }

        /// Chat-only presentation path. This stays intentionally direct: it
        /// compares the current typed rows with the existing document and calls
        /// the document's existing append/replace helpers directly.
        func reload(chatRows: [ChatDisplayRow], transcriptID: TranscriptID?) {
            rendersTypedChatRows = true
            chatRenderExecutor.submit(ChatTranscriptRenderSnapshot(
                context: ChatTranscriptRenderContext(transcriptID: transcriptID),
                rows: chatRows
            ))
        }

        func apply(chatRows: [ChatDisplayRow], transcriptID: TranscriptID?) {
            guard rendersTypedChatRows else {
                reload(chatRows: chatRows, transcriptID: transcriptID)
                return
            }
            chatRenderExecutor.submit(ChatTranscriptRenderSnapshot(
                context: ChatTranscriptRenderContext(transcriptID: transcriptID),
                rows: chatRows
            ))
        }

        func apply(events: [AgentEvent], showsInternals: Bool,
                   transcriptID: TranscriptID? = nil) {
            // Checked BEFORE the `isLoaded` guard, so a transcript switch that
            // lands mid-load also replaces `pendingEvents` — otherwise
            // `didFinish` would render the PREVIOUS transcript's rows and seed
            // `renderedCount` from them, and the new chat would then be diffed
            // against a DOM it never produced.
            //
            // This also hoists the count-decrease check above the guard, where
            // it used to sit below. That is a no-op rather than a behavior
            // change: `reload` sets `renderedCount = 0` and `isLoaded = false`
            // together, and only `didFinish` sets either back — so while
            // unloaded `renderedCount` is always 0 and `count < 0` is
            // unreachable.
            if Self.needsFullReload(
                transcriptID: transcriptID, renderedTranscriptID: renderedTranscriptID,
                showsInternals: showsInternals, renderedShowsInternals: renderedShowsInternals,
                eventCount: events.count, renderedCount: renderedCount) {
                ChatDiagnostics.observe(
                    stage: .recoveryReload,
                    correlation: .init(chat: diagnosticChat(transcriptID), eventKind: .init(rawValue: "legacy-web")),
                    detail: "reload; rows=\(events.count); rendered=\(renderedCount)"
                )
                reload(events: events, showsInternals: showsInternals,
                       transcriptID: transcriptID)
                return
            }
            guard isLoaded else {
                ChatDiagnostics.observe(
                    stage: .renderPlanning,
                    outcome: .coalesced,
                    correlation: .init(chat: diagnosticChat(transcriptID), eventKind: .init(rawValue: "legacy-web")),
                    detail: "pending; rows=\(events.count)"
                )
                pendingEvents = events
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
                    replaceLastRow(last, isStreaming: true)
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
                replaceLastRow(prevLast, isStreaming: false, context: context)
            }
            ChatDiagnostics.observe(
                stage: .renderPlanning,
                correlation: .init(
                    chat: diagnosticChat(transcriptID),
                    eventKind: .init(rawValue: "legacy-web"),
                    content: events.last.flatMap(diagnosticContent)
                ),
                detail: "append; from=\(renderedCount); to=\(events.count)"
            )
            appendRows(Array(events[renderedCount...]), startingIndex: renderedCount, context: context)
            renderedCount = events.count
            renderedLastEvent = events.last
            renderedEvents = events
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            ChatDiagnostics.observe(
                stage: .domAcknowledgement,
                correlation: .init(chat: diagnosticChat(pendingTranscriptID ?? renderedTranscriptID), eventKind: .init(rawValue: "legacy-web")),
                detail: "shell-finished; pending=\(pendingEvents.count)"
            )
            if rendersTypedChatRows {
                beginControlledChatReloadIfNeeded()
                return
            }
            let toRender = pendingEvents
            pendingEvents = []
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

        private func diagnosticChat(_ transcriptID: TranscriptID?) -> ChatDiagnosticCorrelation.Value? {
            guard case .chat(let chatID)? = transcriptID else { return nil }
            return .init(rawValue: chatID.rawValue)
        }

        private func diagnosticContent(_ event: AgentEvent) -> ChatDiagnosticContentFingerprint? {
            switch event {
            case .userText(let text), .assistantText(let text), .thinking(let text), .thinkingDelta(let text), .assistantTextDelta(let text), .result(_, let text):
                return ChatDiagnostics.fingerprint(text)
            default:
                return nil
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
                    if let onChatIntent {
                        onChatIntent(.openWikiLink(url, inNewTab: openInNewTab))
                    } else {
                        onWikiLink?(url, openInNewTab)
                    }
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
            for event in events {
                html += Self.feedRowHTML(for: event, context: context, isFinal: true)
            }
            guard !html.isEmpty,
                  let data = DebugLog.trying("serialize chat rows", operation: { try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]) }),
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
        private func replaceLastRow(_ event: AgentEvent, isStreaming: Bool, context: WikiRenderContext? = nil) {
            let html = Self.feedRowHTML(for: event, context: context, isFinal: !isStreaming)
            guard let data = DebugLog.trying("serialize replaced row", operation: { try JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]) }),
                  let jsonString = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("replaceLastRow(\(jsonString))", completionHandler: nil)
        }

        private func performChatRenderMutation(
            _ command: ChatTranscriptRenderCommand,
            revision: ChatTranscriptRenderRevision,
            acknowledge: @escaping @MainActor (ChatTranscriptRenderAcknowledgement) -> Void
        ) {
            guard let webView else {
                acknowledge(ChatTranscriptRenderAcknowledgement(
                    kind: command.kind, revision: revision, rowID: command.rowID, outcome: .error
                ))
                return
            }
            if case .reload = command {
                followState = ChatTranscriptFollowState.reducing(followState, event: .transcriptReset)
                if isLoaded {
                    guard let reload = chatRenderExecutor.beginReloadMutation() else { return }
                    runControlledChatReload(reload, acknowledge: acknowledge)
                    return
                }
                pendingChatReloadAcknowledgement = acknowledge
                isLoaded = false
                webView.loadHTMLString(Self.shellHTML, baseURL: URL(string: "about:blank"))
                return
            }
            guard let script = chatMutationScript(command, revision: revision, context: currentContext()) else {
                acknowledge(ChatTranscriptRenderAcknowledgement(
                    kind: command.kind, revision: revision, rowID: command.rowID, outcome: .error
                ))
                return
            }
            evaluateChatMutation(
                script,
                expectedKind: command.kind,
                revision: revision,
                expectedRowID: command.rowID,
                acknowledge: acknowledge
            )
        }

        private func beginControlledChatReloadIfNeeded() {
            guard let pendingChatReloadAcknowledgement,
                  let reload = chatRenderExecutor.beginReloadMutation()
            else { return }
            self.pendingChatReloadAcknowledgement = nil
            runControlledChatReload(reload, acknowledge: pendingChatReloadAcknowledgement)
        }

        private func runControlledChatReload(
            _ reload: (snapshot: ChatTranscriptRenderSnapshot, revision: ChatTranscriptRenderRevision),
            acknowledge: @escaping @MainActor (ChatTranscriptRenderAcknowledgement) -> Void
        ) {
            let html = reload.snapshot.rows.map { Self.chatDisplayRowHTML($0, context: currentContext()) }.joined()
            guard let htmlJSON = Self.jsonString(for: html)
            else {
                acknowledge(ChatTranscriptRenderAcknowledgement(
                    kind: .reload, revision: reload.revision, rowID: nil, outcome: .error
                ))
                return
            }
            let follows = followState.followsStreamingContent ? "true" : "false"
            let script = "replaceChatTranscript(\(htmlJSON), \(follows), \(reload.revision.rawValue))"
            evaluateChatMutation(
                script,
                expectedKind: .reload,
                revision: reload.revision,
                expectedRowID: nil,
                acknowledge: acknowledge
            )
        }

        private func chatMutationScript(
            _ command: ChatTranscriptRenderCommand,
            revision: ChatTranscriptRenderRevision,
            context: WikiRenderContext?
        ) -> String? {
            let follows = followState.followsStreamingContent ? "true" : "false"
            let revisionValue = revision.rawValue
            switch command {
            case .reload:
                return nil
            case .append(let rows):
                let html = rows.map { Self.chatDisplayRowHTML($0, context: context) }.joined()
                guard let htmlJSON = Self.jsonString(for: html),
                      let rowIDJSON = Self.jsonString(for: rows.last?.id.domValue ?? "")
                else { return nil }
                return "appendChatRows(\(htmlJSON), \(follows), \(revisionValue), \(rowIDJSON))"
            case .insert(let row, let before):
                guard let rowIDJSON = Self.jsonString(for: row.id.domValue),
                      let beforeIDJSON = Self.jsonString(for: before.domValue),
                      let htmlJSON = Self.jsonString(for: Self.chatDisplayRowHTML(row, context: context))
                else { return nil }
                return "insertChatRow(\(rowIDJSON), \(beforeIDJSON), \(htmlJSON), \(follows), \(revisionValue))"
            case .replace(let row):
                guard let rowIDJSON = Self.jsonString(for: row.id.domValue),
                      let htmlJSON = Self.jsonString(for: Self.chatDisplayRowHTML(row, context: context))
                else { return nil }
                return "replaceChatRow(\(rowIDJSON), \(htmlJSON), \(follows), \(revisionValue))"
            case .remove(let rowID):
                guard let rowIDJSON = Self.jsonString(for: rowID.domValue) else { return nil }
                return "removeChatRow(\(rowIDJSON), \(revisionValue))"
            }
        }

        private func evaluateChatMutation(
            _ script: String,
            expectedKind: ChatTranscriptRenderCommandKind,
            revision: ChatTranscriptRenderRevision,
            expectedRowID: ChatDisplayRowID?,
            acknowledge: @escaping @MainActor (ChatTranscriptRenderAcknowledgement) -> Void
        ) {
            guard let webView else {
                acknowledge(ChatTranscriptRenderAcknowledgement(
                    kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .error
                ))
                return
            }
            Task { @MainActor in
                let result = await webView.chatTranscriptJavaScriptResult(script)
                acknowledge(Self.acknowledgement(
                    from: result,
                    expectedKind: expectedKind,
                    revision: revision,
                    expectedRowID: expectedRowID
                ))
            }
        }

        private static func acknowledgement(
            from result: ChatTranscriptJavaScriptResult,
            expectedKind: ChatTranscriptRenderCommandKind,
            revision: ChatTranscriptRenderRevision,
            expectedRowID: ChatDisplayRowID?
        ) -> ChatTranscriptRenderAcknowledgement {
            switch result {
            case .undefined:
                return .init(kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .undefined)
            case .javaScriptException(let message):
                DebugLog.store("chat transcript JavaScript exception: \(message)")
                return .init(kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .javaScriptException)
            case .timeout:
                DebugLog.store("chat transcript JavaScript evaluation timed out")
                return .init(kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .timeout)
            case .success(let value):
                guard JSONSerialization.isValidJSONObject(value) else {
                    return .init(kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .error)
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: value)
                    let wire = try JSONDecoder().decode(DOMAcknowledgement.self, from: data)
                    guard let kind = ChatTranscriptRenderCommandKind(rawValue: wire.kind) else {
                        return .init(kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .error)
                    }
                    return .init(
                        kind: kind,
                        revision: .init(rawValue: wire.revision),
                        rowID: wire.rowID.flatMap(ChatDisplayRowID.init(domValue:)),
                        outcome: ChatTranscriptRenderAcknowledgementOutcome(rawValue: wire.outcome) ?? .error
                    )
                } catch {
                    DebugLog.store("decode chat transcript acknowledgement: \(error)")
                    return .init(kind: expectedKind, revision: revision, rowID: expectedRowID, outcome: .error)
                }
            }
        }

        private struct DOMAcknowledgement: Decodable {
            let kind: String
            let revision: Int
            let rowID: String?
            let outcome: String
        }

        private static func jsonString(for value: String) -> String? {
            guard let data = DebugLog.trying("serialize chat row", operation: {
                try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            }) else { return nil }
            return String(data: data, encoding: .utf8)
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
            else {
                if message.name == ChatWebView.followMessageName,
                   let body = message.body as? [String: Any],
                   let distance = body["distanceFromBottom"] as? Double {
                    followState = ChatTranscriptFollowState.reducing(
                        followState,
                        event: .viewportChanged(distanceFromBottom: distance)
                    )
                }
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        // MARK: - Row rendering

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

        /// Direct typed chat markup used by the Phase 4 transcript surface.
        /// Every durable row becomes one semantic DOM element with a stable
        /// attribute; that attribute is presentation metadata, not a rendering
        /// command protocol.
        static func chatDisplayRowHTML(_ row: ChatDisplayRow, context: WikiRenderContext? = nil) -> String {
            let rowID = htmlAttributeEscape(row.id.domValue)
            let turnAttribute = row.turnID.map { " data-turn-id=\"\(htmlAttributeEscape($0.rawValue))\"" } ?? ""
            let attributes = " data-row-id=\"\(rowID)\"\(turnAttribute)"

            switch row {
            case .userMessage(_, _, let text, _):
                return """
                <article class="row chat-row chat-user" role="article" aria-label="Your message"\(attributes)>
                <div class="bubble">\(renderedMarkdown(text, context: context))</div></article>
                """

            case .assistantMessage(_, _, let text, let createdAt, let contentState):
                let stateLabel = contentState == .streaming ? "Streaming response" : "Assistant response"
                let status = contentState == .streaming ? "Streaming" : "Completed"
                let timestamp = formatTimestamp(createdAt)
                return """
                <article class="row chat-row chat-assistant\(contentState == .streaming ? " is-streaming" : "")" role="article" aria-label="\(stateLabel)" aria-busy="\(contentState == .streaming ? "true" : "false")"\(attributes)>
                <div class="bubble">\(renderedMarkdown(text, context: context, isFinal: contentState == .final))</div>
                <div class="turn-footer"><span class="row-status" aria-label="\(status)">\(contentState == .streaming ? "◌ Streaming" : "✓ Completed")</span><button class="copy-btn" type="button" data-copy="\(htmlAttributeEscape(text))" data-focus-key="copy" aria-label="Copy assistant response" title="Copy assistant response">\(Self.copyIconSVG)</button><span class="turn-meta" aria-label="Response recorded at \(escape(timestamp))"><span class="turn-timestamp">\(escape(timestamp))</span></span></div>
                </article>
                """

            case .reasoning(_, _, let text, _, let contentState):
                let state = contentState == .streaming ? "streaming" : "completed"
                let preview = String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                let previewShort = preview.count > ChatTranscriptPresentationMetrics.reasoningPreviewLength
                    ? String(preview.prefix(ChatTranscriptPresentationMetrics.reasoningPreviewLength)) + "…"
                    : preview
                return """
                <details class="row chat-row row-thinking collapsible\(contentState == .streaming ? " is-streaming" : "")" role="group" aria-label="Reasoning, \(state)"\(attributes)>
                <summary data-focus-key="disclosure" aria-label="Show reasoning, \(state)"><span class="row-status" aria-hidden="true">\(contentState == .streaming ? "◌" : "✓")</span> <span class="row-thinking-label">Reasoning</span> <span class="row-thinking-preview">\(escape(previewShort))</span></summary>
                <div class="row-thinking-body">\(renderedMarkdown(text, context: context, isFinal: contentState == .final))</div></details>
                """

            case .toolCall(_, _, let toolName, let status, let detail, let output, _, _):
                let statusText = toolStatusLabel(status)
                let isError = status == .failed || status == .cancelled
                let summaryText = toolSummary(descriptor: detail, output: output, fallback: toolName)
                let outputText = output ?? detail ?? ""
                let cue = isError ? "⚠" : (status == .running || status == .pending ? "◌" : "✓")
                return """
                <details class="row chat-row chat-tool\(isError ? " is-error" : "")\((status == .running || status == .pending) ? " is-running" : "")" role="group" aria-label="Tool \(escape(toolName)), \(statusText)"\(attributes)>
                <summary data-focus-key="disclosure" aria-label="Show tool details for \(escape(toolName)), \(statusText)"><span class="row-status" aria-hidden="true">\(cue)</span> <span class="chat-tool-name">\(escape(toolName))</span><span class="chat-tool-summary">\(escape(statusText))\(summaryText.isEmpty ? "" : " — \(escape(summaryText))")</span></summary>
                \(outputText.isEmpty ? "" : "<pre class=\"chat-tool-detail\">\(escape(outputText))</pre>")</details>
                """

            case .notice(_, _, _, let title, let message, _):
                return """
                <aside class="row chat-notice" role="status" aria-label="Notice: \(escape(title))"\(attributes)><span class="row-status" aria-hidden="true">ⓘ</span><div><strong>\(escape(title))</strong><div>\(renderedMarkdown(message, context: context))</div></div></aside>
                """

            case .failure(_, _, _, let message, _):
                return """
                <aside class="row row-turn-failed" role="alert" aria-label="Chat action failed"\(attributes)><span class="row-turn-failed-icon" aria-hidden="true">⚠︎</span><div class="row-turn-failed-body"><strong>Chat action failed</strong> \(escape(message))</div></aside>
                """
            }
        }

        /// Returns a collapsed descriptor without mutating durable output. New
        /// rows retain an input descriptor; legacy rows may have only output,
        /// whose Markdown fence is skipped for this compact presentation.
        private static func toolSummary(descriptor: String?, output: String?, fallback: String) -> String {
            previewText(in: descriptor) ?? previewText(in: output) ?? fallback
        }

        private static func previewText(in text: String?) -> String? {
            guard let text else { return nil }
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { line in
                    !line.isEmpty && !isMarkdownFence(line)
                })
        }

        private static func isMarkdownFence(_ line: String) -> Bool {
            line.hasPrefix("```") || line.hasPrefix("~~~")
        }

        private static func toolStatusLabel(_ status: ChatToolCallStatus) -> String {
            switch status {
            case .pending: "Pending"
            case .running: "Running"
            case .completed: "Completed"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        /// Inline SVG for the copy button (lucide `Copy` icon, inner `currentColor`
        /// so CSS controls the tint). Duplicated as a JS string in `shellHTML`
        /// so the click handler can swap between copy↔check without a round-trip.
        private static let copyIconSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>"#

        /// Inline SVG for the post-copy checkmark (lucide `Check` icon) — shown for
        /// ~1.5 s to confirm the clipboard write landed.
        private static let checkIconSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>"#

        /// Format a typed row's creation time. Same-day rows show only the time;
        /// older rows show the date and time.
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
        static func jsEscape(_ s: String) -> String {
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
            font-size: 13px; line-height: 1.55; color: var(--text);
            /* Right-side padding keeps content clear of the WebView's scrollbar
               so the right margin matches the left (which has no scrollbar). */
            padding: 10px 12px 10px 0; -webkit-font-smoothing: antialiased;
            /* Never let content exceed the web view's width — long tokens/URLs
               in list items and paragraphs wrap instead of clipping off the
               right edge or pushing list markers off the left. */
            overflow-wrap: break-word; word-wrap: break-word;
          }
          .row { margin: 0 0 8px; }
          article.row, aside.row { max-width: 72ch; }
          .row-status { font-variant-numeric: tabular-nums; font-size: 11px; }
          .is-streaming .row-status, .is-running .row-status { font-weight: 600; }
          .chat-notice {
            display: flex; gap: 7px; align-items: first baseline; padding: 8px 10px;
            background: var(--code-bg); border-left: 3px solid var(--border);
            border-radius: 6px; color: var(--text); font-size: 12px;
          }
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
          /* Footer actions and completion metadata stay attached to each typed response. */
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
          .chat-assistant:focus-within .copy-btn { opacity: 1; }
          .copy-btn:hover { opacity: 1; color: var(--text); background: var(--code-bg); }
          .copy-btn.copied { opacity: 1; color: #34c759; }
          .copy-btn svg { display: block; }
          .turn-meta {
            font-size: 11px; color: var(--muted); white-space: nowrap;
          }
          .turn-timestamp { opacity: 0.7; }
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
          .sr-only {
            position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
            overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
          }
          @media (prefers-reduced-motion: reduce) {
            *, *::before, *::after { scroll-behavior: auto !important; transition: none !important; }
          }
        </style>
        </head><body>
        <main id="chat-transcript" aria-live="polite"></main>
        <script>
          function transcriptRoot() { return document.getElementById('chat-transcript'); }
          function renderAcknowledgement(kind, revision, rowID, outcome) {
            return {kind: kind, revision: revision, rowID: rowID || null, outcome: outcome};
          }
          function isNearBottom() {
            return Math.max(0, document.documentElement.scrollHeight - (window.scrollY + window.innerHeight)) <= 72;
          }
          function reportFollowState() {
            try {
              window.webkit.messageHandlers.chatFollowState.postMessage({distanceFromBottom: Math.max(0, document.documentElement.scrollHeight - (window.scrollY + window.innerHeight))});
            } catch (err) { }
          }
          function appendRows(html, shouldFollow) {
            var wasNearBottom = isNearBottom();
            transcriptRoot().insertAdjacentHTML('beforeend', html);
            if (shouldFollow && wasNearBottom) window.scrollTo(0, document.body.scrollHeight);
            reportFollowState();
          }
          function replaceLastRow(html) {
            var root = transcriptRoot();
            if (root.lastElementChild) {
              root.lastElementChild.outerHTML = html;
            } else {
              root.insertAdjacentHTML('beforeend', html);
            }
            window.scrollTo(0, document.body.scrollHeight);
          }
          function selectionOffsets(root) {
            var selection = window.getSelection();
            if (!selection || selection.rangeCount !== 1) return null;
            var range = selection.getRangeAt(0);
            if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) return null;
            function offset(node, container, offset) {
              var walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, null);
              var count = 0, current;
              while ((current = walker.nextNode())) {
                if (current === container) return count + offset;
                count += current.nodeValue.length;
              }
              return count;
            }
            return [offset(root, range.startContainer, range.startOffset), offset(root, range.endContainer, range.endOffset)];
          }
          function textPoint(root, target) {
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
            var count = 0, current;
            while ((current = walker.nextNode())) {
              var next = count + current.nodeValue.length;
              if (target <= next) return [current, Math.max(0, target - count)];
              count = next;
            }
            return [root, root.childNodes.length];
          }
          function restoreRowInteraction(state) {
            if (!state) return;
            var anchor = state.anchorRowID && document.querySelector('[data-row-id="' + CSS.escape(state.anchorRowID) + '"]');
            if (anchor && !state.wasNearBottom) window.scrollBy(0, anchor.getBoundingClientRect().top - state.anchorTop);
            var focusRow = state.focusRowID && document.querySelector('[data-row-id="' + CSS.escape(state.focusRowID) + '"]');
            if (focusRow && state.focusKey) {
              var focus = focusRow.querySelector('[data-focus-key="' + CSS.escape(state.focusKey) + '"]');
              if (focus) focus.focus({preventScroll:true});
            }
            var selectionRow = state.selectionRowID && document.querySelector('[data-row-id="' + CSS.escape(state.selectionRowID) + '"]');
            if (selectionRow && state.offsets) {
              var start = textPoint(selectionRow, state.offsets[0]), end = textPoint(selectionRow, state.offsets[1]);
              var range = document.createRange(); range.setStart(start[0], start[1]); range.setEnd(end[0], end[1]);
              var selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            }
          }
          function currentRowInteraction() {
            var root = transcriptRoot();
            var active = document.activeElement;
            var activeRow = active && active.closest && active.closest('[data-row-id]');
            var selection = window.getSelection();
            var selectionRow = selection && selection.rangeCount === 1 && selection.getRangeAt(0).startContainer.parentElement && selection.getRangeAt(0).startContainer.parentElement.closest('[data-row-id]');
            var anchorRow = Array.from(root.children).find(function(row) { return row.getBoundingClientRect().bottom >= 0; });
            return {
              wasNearBottom: isNearBottom(),
              focusRowID: activeRow && activeRow.getAttribute('data-row-id'),
              focusKey: activeRow && active.getAttribute('data-focus-key'),
              selectionRowID: selectionRow && selectionRow.getAttribute('data-row-id'),
              offsets: selectionRow && selectionOffsets(selectionRow),
              anchorRowID: anchorRow && anchorRow.getAttribute('data-row-id'),
              anchorTop: anchorRow ? anchorRow.getBoundingClientRect().top : 0
            };
          }
          function appendChatRows(html, shouldFollow, revision, rowID) {
            try {
              appendRows(html, shouldFollow);
              var row = rowID && document.querySelector('[data-row-id="' + CSS.escape(rowID) + '"]');
              return renderAcknowledgement('append', revision, rowID, rowID && !row ? 'missingRow' : 'success');
            } catch (error) {
              return renderAcknowledgement('append', revision, rowID, 'error');
            }
          }
          function insertChatRow(rowID, beforeRowID, html, shouldFollow, revision) {
            try {
              var before = document.querySelector('[data-row-id="' + CSS.escape(beforeRowID) + '"]');
              if (!before) return renderAcknowledgement('insert', revision, rowID, 'missingRow');
              var wasNearBottom = isNearBottom();
              before.insertAdjacentHTML('beforebegin', html);
              if (!document.querySelector('[data-row-id="' + CSS.escape(rowID) + '"]')) return renderAcknowledgement('insert', revision, rowID, 'missingRow');
              if (shouldFollow && wasNearBottom) window.scrollTo(0, document.body.scrollHeight);
              reportFollowState();
              return renderAcknowledgement('insert', revision, rowID, 'success');
            } catch (error) {
              return renderAcknowledgement('insert', revision, rowID, 'error');
            }
          }
          function removeChatRow(rowID, revision) {
            try {
              var row = document.querySelector('[data-row-id="' + CSS.escape(rowID) + '"]');
              if (!row) return renderAcknowledgement('remove', revision, rowID, 'missingRow');
              row.remove(); reportFollowState();
              return renderAcknowledgement('remove', revision, rowID, 'success');
            } catch (error) {
              return renderAcknowledgement('remove', revision, rowID, 'error');
            }
          }
          function replaceChatTranscript(html, shouldFollow, revision) {
            try {
              var state = currentRowInteraction();
              transcriptRoot().innerHTML = html;
              restoreRowInteraction(state);
              if (shouldFollow && state.wasNearBottom) window.scrollTo(0, document.body.scrollHeight);
              reportFollowState();
              return renderAcknowledgement('reload', revision, null, 'success');
            } catch (error) {
              return renderAcknowledgement('reload', revision, null, 'error');
            }
          }
          function replaceChatRow(rowID, html, shouldFollow, revision) {
            var oldRow = document.querySelector('[data-row-id="' + CSS.escape(rowID) + '"]');
            if (!oldRow) return renderAcknowledgement('replace', revision, rowID, 'missingRow');
            var wasNearBottom = isNearBottom();
            var active = document.activeElement;
            var focusKey = active && oldRow.contains(active) ? active.getAttribute('data-focus-key') : null;
            var offsets = selectionOffsets(oldRow);
            oldRow.outerHTML = html;
            var newRow = document.querySelector('[data-row-id="' + CSS.escape(rowID) + '"]');
            if (!newRow) return renderAcknowledgement('replace', revision, rowID, 'missingRow');
            if (focusKey) {
              var replacementFocus = newRow.querySelector('[data-focus-key="' + CSS.escape(focusKey) + '"]');
              if (replacementFocus) replacementFocus.focus({preventScroll:true});
            }
            if (offsets) {
              var start = textPoint(newRow, offsets[0]), end = textPoint(newRow, offsets[1]);
              var range = document.createRange(); range.setStart(start[0], start[1]); range.setEnd(end[0], end[1]);
              var selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
            }
            if (shouldFollow && wasNearBottom) window.scrollTo(0, document.body.scrollHeight);
            reportFollowState();
            return renderAcknowledgement('replace', revision, rowID, 'success');
          }
          window.addEventListener('scroll', reportFollowState, {passive:true});
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
