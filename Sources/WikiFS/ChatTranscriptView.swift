import SwiftUI
import WikiFSCore

/// Output-first chat surface for the dedicated Query page. Internal stream-json
/// bookkeeping stays in AgentActivityView behind "Show internals".
struct ChatTranscriptView: View {
    @Bindable var launcher: AgentLauncher
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives (the parent `ChatView`) and forwarded
    /// unchanged to the transcript web view.
    var onWikiLink: ((URL, Bool) -> Void)? = nil
    /// Provider of the current `WikiRenderContext` (Phase A.2) — bound to
    /// `store.renderContext()` by `ChatView`, so live chat rows
    /// render source references exactly as the reader does. Forwarded unchanged
    /// to the transcript web view.
    var renderContext: (() -> WikiRenderContext?)? = nil
    /// The store backing `wiki-blob://` blob serving for the transcript's
    /// images/media. Forwarded to the transcript web view.
    var blobStore: WikiStoreModel? = nil
    /// Page-zoom multiplier forwarded to the transcript web view. Bound to the
    /// `chat.zoom` AppStorage by the chat surface.
    var zoom: Double = Double(ZoomScale.defaultScale)
    /// Versioned scroll-to-turn request, forwarded to the transcript web view.
    var scrollRequest: ChatScrollRequest? = nil

    var body: some View {
        Group {
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
                    scrollRequest: scrollRequest
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var visibleEvents: [AgentEvent] {
        launcher.events.transcriptVisible
    }

    private var placeholder: some View {
        VStack(spacing: 7) {
            Text(launcher.isRunning ? "Waiting for the Agent..." : "Ask a question to start a chat.")
                .font(.headline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text("Answers appear here; one-line tool-call summaries show as the agent works. Full detail is available under “Show internals.”")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(ChatTranscriptMetrics.emptyStatePadding)
    }
}

private enum ChatTranscriptMetrics {
    static let emptyStatePadding: CGFloat = 24
}

extension [AgentEvent] {
    /// The transcript-visible subset shared by the live Query page and the
    /// read-only chat-history view, so a persisted chat re-renders
    /// exactly like it looked live.
    var transcriptVisible: [AgentEvent] {
        filter { event in
            switch event {
            case .result(_, let text):
                return !hasAssistantText(matching: text)
            case .toolUse:
                // A concise one-line progress summary per tool call (issue #173):
                // lets the user see the agent reading/searching/editing without
                // opting into the full internals view. Full raw detail still lives
                // behind "Show internals".
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
