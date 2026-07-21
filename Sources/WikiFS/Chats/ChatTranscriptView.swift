import SwiftUI
import WikiFSCore

/// The reusable chat-transcript component for BOTH the live (streaming) and the
/// persisted (read-only) chat surfaces. Rendered from a caller-supplied `events`
/// array (already `transcriptVisible`-filtered), so the live path feeds
/// `launcher.events` and the persisted path feeds `store.chatMessages` through
/// the same view — collapsing the old dual render sites in `ChatDetailView`.
struct ChatTranscriptView: View {
    /// The transcript-visible events to render (caller pre-filters via
    /// `[AgentEvent].transcriptVisible`).
    let events: [AgentEvent]
    /// Wall-clock timestamps parallel to `events` (after the same filtering).
    /// `nil` entries produce no "Worked for" footer. Used to render the
    /// duration metadata under assistant responses.
    var timestamps: [Date?] = []
    /// Idle/fallback empty-state message. Overridden by "Waiting for the
    /// Agent…" while `isRunning` (the live streaming case).
    var emptyStateMessage: String
    /// True while a live session is streaming into this transcript. Shows the
    /// "Waiting for the Agent…" placeholder and the streaming hint; the
    /// persisted surface passes `false` (it is never the active stream).
    var isRunning: Bool = false
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives (the parent `ChatDetailView`) and forwarded unchanged to
    /// the transcript web view.
    var onWikiLink: ((URL, Bool) -> Void)? = nil
    /// Provider of the current `WikiRenderContext` (Phase A.2) — bound to
    /// `store.renderContext()` by `ChatDetailView`, so chat rows render source
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
        // Mirror the hideToolCalls filter on both events and timestamps so
        // they stay parallel. When hideToolCalls is on, remove tool-call
        // events and their corresponding timestamps.
        let visibleEvents = hideToolCalls ? events.filter { !$0.isToolCall } : events
        let visibleTimestamps = hideToolCalls
            ? events.indices.compactMap { idx -> Date? in
                guard !events[idx].isToolCall else { return nil }
                return idx < timestamps.count ? timestamps[idx] : nil
            }
            : timestamps
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
                    quoteAnchor: quoteAnchor,
                    timestamps: visibleTimestamps
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
    /// The indices of transcript-visible events (same filtering rule as
    /// `transcriptVisible`). Returned so callers that carry parallel arrays
    /// (timestamps, etc.) can filter them in lockstep without duplicating the
    /// predicate.
    var transcriptVisibleIndices: [Int] {
        indices.filter { self[$0].isVisibleInTranscript(in: self) }
    }

    /// The transcript-visible subset shared by the live chat surface and the
    /// read-only chat-history view, so a persisted chat re-renders
    /// exactly like it looked live.
    var transcriptVisible: [AgentEvent] {
        transcriptVisibleIndices.map { self[$0] }
    }
}
