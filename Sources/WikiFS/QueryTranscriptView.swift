import SwiftUI
import WikiFSCore

/// Output-first chat surface for the dedicated Query page. Internal stream-json
/// bookkeeping stays in AgentActivityView behind "Show internals".
struct QueryTranscriptView: View {
    @Bindable var launcher: AgentLauncher
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives (the parent `QueryConversationView`) and forwarded
    /// unchanged to the transcript web view.
    var onWikiLink: ((URL, Bool) -> Void)? = nil

    var body: some View {
        Group {
            if visibleEvents.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                AgentTranscriptWebView(events: visibleEvents, style: .chat, onWikiLink: onWikiLink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var visibleEvents: [AgentEvent] {
        launcher.events.filter { event in
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
        return launcher.events.contains { event in
            if case .assistantText(let assistantText) = event {
                return assistantText.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
            }
            return false
        }
    }

    private var placeholder: some View {
        VStack(spacing: 7) {
            Text(launcher.isRunning ? "Waiting for the Agent..." : "Ask a question to start a conversation.")
                .font(.headline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text("Answers appear here; one-line tool-call summaries show as the agent works. Full detail is available under “Show internals.”")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(QueryTranscriptMetrics.emptyStatePadding)
    }
}

private enum QueryTranscriptMetrics {
    static let emptyStatePadding: CGFloat = 24
}
