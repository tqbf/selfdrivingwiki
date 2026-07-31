// pattern: Imperative Shell

import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The live activity feed for an ACP-driven agent run — the "Agent Queue."
/// Shows a real-time typed transcript of agent work and results as it executes.
struct AgentQueueView: View {
    /// The daemon-mirrored chat session replaces the in-process launcher.
    /// Run-state reads come from typed chat synchronization envelopes.
    var remoteSession: RemoteChatSession
    let showsInternals: Bool
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives and threaded down; `nil` when navigation is
    /// impossible (links still render, just don't navigate).
    var onWikiLink: ((URL, Bool) -> Void)? = nil

    init(remoteSession: RemoteChatSession, showsInternals: Bool = false, onWikiLink: ((URL, Bool) -> Void)? = nil) {
        self.remoteSession = remoteSession
        self.showsInternals = showsInternals
        self.onWikiLink = onWikiLink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = remoteSession.preflightError {
                preflightBanner(error)
            }
            if showsInternals {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    AgentRunStatusView(remoteSession: remoteSession, now: context.date)
                        .padding(.horizontal, ActivityMetrics.padding)
                        .padding(.top, ActivityMetrics.padding)
                }
            }
            activityFeed
            if showsInternals && !remoteSession.stderr.isEmpty {
                stderrBanner
            }
        }
        // Selection + copy across the whole feed happens inside
        // `ChatTranscriptView`'s single document. This only covers the
        // placeholder/banner `Text` views outside it.
        .textSelection(.enabled)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var activityFeed: some View {
        if showsPlaceholder {
            placeholder
                .padding(ActivityMetrics.padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ChatTranscriptView(
                rendering: .init(transcript: remoteSession.displayTranscript),
                transcriptID: remoteSession.chatID.chatID.map(TranscriptID.chat),
                emptyStateMessage: "No activity yet.",
                isStreaming: remoteSession.runState.isAnswering,
                onIntent: handleTranscriptIntent
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsPlaceholder: Bool {
        remoteSession.displayTranscript.rows.isEmpty && remoteSession.preflightError == nil
    }

    private func handleTranscriptIntent(_ intent: ChatTranscriptIntent) {
        switch intent {
        case .openWikiLink(let url, let inNewTab):
            onWikiLink?(url, inNewTab)
        case .resolvePermission:
            break
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if remoteSession.runState.isLive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(showsInternals ? (remoteSession.runningKind.map { "Starting \($0.title)…" } ?? "Starting…") : "Waiting for output…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(showsInternals ? "No activity yet. Choose an operation and press Run." : "No output yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Agent Queue")
                .font(.headline)
            Text("Live transcript of agent tool calls, diagnostics, and results as the agent runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ActivityMetrics.padding)
        .padding(.top, ActivityMetrics.padding)
        .padding(.bottom, ActivityMetrics.padding)
    }

    private func preflightBanner(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(ActivityMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.12))
    }

    private var stderrBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Diagnostics", systemImage: "ladybug.fill")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
            Text(remoteSession.stderr)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ActivityMetrics.padding)
        .background(.orange.opacity(0.10))
    }
}

private enum ActivityMetrics {
    static let padding: CGFloat = 10
}
