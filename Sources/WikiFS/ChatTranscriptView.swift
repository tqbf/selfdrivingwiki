import SwiftUI
import WikiFSCore

/// The reusable chat-transcript component for BOTH the live (streaming) and the
/// persisted (read-only) chat surfaces. Rendered from a caller-supplied `events`
/// array (already `transcriptVisible`-filtered), so the live path feeds
/// `launcher.events` and the persisted path feeds `store.chatMessages` through
/// the same view — collapsing the old dual render sites in `ChatView`.
struct ChatTranscriptView: View {
    /// The transcript-visible events to render (caller pre-filters via
    /// `[AgentEvent].transcriptVisible`).
    let events: [AgentEvent]
    /// Idle/fallback empty-state message. Overridden by "Waiting for the
    /// Agent…" while `isRunning` (the live streaming case).
    var emptyStateMessage: String
    /// True while a live session is streaming into this transcript. Shows the
    /// "Waiting for the Agent…" placeholder and the streaming hint; the
    /// persisted surface passes `false` (it is never the active stream).
    var isRunning: Bool = false
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives (the parent `ChatView`) and forwarded unchanged to
    /// the transcript web view.
    var onWikiLink: ((URL, Bool) -> Void)? = nil
    /// Provider of the current `WikiRenderContext` (Phase A.2) — bound to
    /// `store.renderContext()` by `ChatView`, so chat rows render source
    /// references exactly as the reader does. Forwarded unchanged to the
    /// transcript web view.
    var renderContext: (() -> WikiRenderContext?)? = nil
    /// The store backing `wiki-blob://` blob serving for the transcript's
    /// images/media. Forwarded to the transcript web view.
    var blobStore: WikiStoreModel? = nil
    /// Page-zoom multiplier forwarded to the transcript web view. Bound to the
    /// `chat.zoom` AppStorage by the chat surface.
    var zoom: Double = Double(ZoomScale.defaultScale)
    /// Versioned scroll-to-turn request, forwarded to the transcript web view.
    var scrollRequest: ChatScrollRequest? = nil
    /// Versioned quote-anchor highlight request (`[[chat:Title#"quote"]]`,
    /// issue #281), forwarded to the transcript web view.
    var quoteAnchor: ChatHighlightRequest? = nil
    /// When true, tool-call rows are filtered from the transcript (issue #381).
    var hideToolCalls: Bool = false

    var body: some View {
        let visibleEvents = hideToolCalls ? events.filter { !$0.isToolCall } : events
        return Group {
            if visibleEvents.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ChatWebView(
                    events: visibleEvents,
                    style: .chat,
                    onWikiLink: onWikiLink,
                    renderContext: renderContext,
                    blobStore: blobStore,
                    zoom: zoom,
                    scrollRequest: scrollRequest,
                    quoteAnchor: quoteAnchor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 7) {
            Text(isRunning ? "Waiting for the Agent..." : emptyStateMessage)
                .font(.headline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            // The streaming hint only applies while the agent is actively
            // working this transcript; a persisted (read-only) empty state shows
            // just its message.
            if isRunning {
                Text("Answers appear here; one-line tool-call summaries show as the agent works. Full detail is available under “Show internals.”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(ChatTranscriptMetrics.emptyStatePadding)
    }
}

private enum ChatTranscriptMetrics {
    static let emptyStatePadding: CGFloat = 24
}

extension [AgentEvent] {
    /// The transcript-visible subset shared by the live chat surface and the
    /// read-only chat-history view, so a persisted chat re-renders
    /// exactly like it looked live.
    var transcriptVisible: [AgentEvent] {
        filter { event in
            switch event {
            case .result(_, let text):
                return !hasAssistantText(matching: text)
            case .toolUse, .thinking:
                // A concise one-line progress summary per tool call (issue #173):
                // lets the user see the agent reading/searching/editing without
                // opting into the full internals view. Full raw detail still lives
                // behind "Show internals".
                // .thinking is surfaced as a collapsible box (issue #391) —
                // distinct from the full internals feed.
                return true
            case .toolResult(let isError, _):
                // Surface failed tool calls (a useful stall/error signal); successes
                // are implied by the agent's next action or final answer.
                return isError
            default:
                return !event.isInternalTranscriptEvent
            }
        }
    }

    private func hasAssistantText(matching text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return contains { event in
            if case .assistantText(let assistantText) = event {
                return assistantText.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
            }
            return false
        }
    }
}
