import SwiftUI
import WikiFSCore

/// The reusable chat transcript renderer. Its input is a single renderer-only
/// bridge from the typed app presentation model, not an app event contract.
struct ChatTranscriptView: View {
    let rendering: ChatTranscriptRenderingInput
    /// Identity of the conversation `events` belongs to, forwarded to
    /// `ChatWebView` so its incremental differ rebuilds instead of splicing
    /// when this view is reused for a different chat (see
    /// `ChatWebView.transcriptID`). `nil` for the draft composer, which never
    /// reaches the web view (it renders the empty-state placeholder).
    var transcriptID: TranscriptID? = nil
    /// Idle/fallback empty-state message. Overridden by "Waiting for the
    /// Agent…" while `isStreaming` (the live streaming case).
    var emptyStateMessage: String
    /// True while a live session is streaming into this transcript. Shows the
    /// "Waiting for the Agent…" placeholder and the streaming hint; the
    /// persisted surface passes `false` (it is never the active stream).
    var isStreaming: Bool = false
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
    var scrollRequest: ChatWebScrollRequest? = nil
    /// Versioned quote-anchor highlight request (`[[chat:Title#"quote"]]`,
    /// issue #281), forwarded to the transcript web view.
    var quoteAnchor: ChatHighlightRequest? = nil
    /// When true, tool-call rows are filtered from the transcript (issue #381).
    var hideToolCalls: Bool = false

    var body: some View {
        // Mirror the hideToolCalls filter on both events and timestamps so
        // they stay parallel. When hideToolCalls is on, remove tool-call
        // events and their corresponding timestamps.
        let transcriptIndices = rendering.events.transcriptVisibleIndices
        let transcriptEvents = transcriptIndices.map { rendering.events[$0] }
        let transcriptTimestamps = transcriptIndices.map { index in
            index < rendering.timestamps.count ? rendering.timestamps[index] : nil
        }
        let visibleEvents = hideToolCalls ? transcriptEvents.filter { !$0.isToolCall } : transcriptEvents
        let visibleTimestamps = hideToolCalls
            ? transcriptEvents.indices.compactMap { idx -> Date? in
                guard !transcriptEvents[idx].isToolCall else { return nil }
                return idx < transcriptTimestamps.count ? transcriptTimestamps[idx] : nil
            }
            : transcriptTimestamps
        return Group {
            if visibleEvents.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ChatWebView(
                    events: visibleEvents,
                    style: .chat,
                    transcriptID: transcriptID,
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
            Text(isStreaming ? "Waiting for the Agent..." : emptyStateMessage)
                .font(.headline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            // The streaming hint only applies while the agent is actively
            // working this transcript; a persisted (read-only) empty state shows
            // just its message.
            if isStreaming {
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

/// Narrow renderer bridge retained until Phase 4 replaces the existing WebKit
/// event renderer. Presentation state never stores these compatibility events
/// or exposes a timestamp-array API.
struct ChatTranscriptRenderingInput {
    let rows: [ChatDisplayRow]
    let events: [AgentEvent]
    let timestamps: [Date?]

    init(transcript: ChatDisplayTranscript) {
        self.rows = transcript.rows
        self.events = rows.map(Self.event)
        self.timestamps = rows.map { $0.timestamp }
    }

    func webScrollRequest(for request: ChatScrollRequest?) -> ChatWebScrollRequest? {
        guard let request,
              case .turn(_, let promptRowID) = request.target,
              let rowIndex = rows.firstIndex(where: { $0.id == promptRowID }) else {
            return nil
        }
        let turnIndex = rows[..<rowIndex].reduce(into: 0) { count, row in
            if row.isPrompt { count += 1 }
        }
        return ChatWebScrollRequest(version: request.version, turnIndex: turnIndex)
    }

    private static func event(for row: ChatDisplayRow) -> AgentEvent {
        switch row {
        case .userMessage(_, _, let text, _):
            .userText(text)
        case .assistantMessage(_, _, let text, _, _):
            .assistantText(text)
        case .reasoning(_, _, let text, _, _):
            .thinking(text)
        case .toolCall(_, _, let toolName, let status, let detail, _, _):
            switch status {
            case .pending, .running:
                .toolUse(name: toolName, inputSummary: detail ?? "")
            case .completed:
                .toolResult(isError: false, summary: detail ?? toolName)
            case .failed, .cancelled:
                .toolResult(isError: true, summary: detail ?? toolName)
            }
        case .notice(_, _, _, let title, let message, _):
            .assistantText("\(title)\n\n\(message)")
        case .failure(_, _, _, let message, _):
            .turnFailed(reason: .agentError(message))
        }
    }
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
