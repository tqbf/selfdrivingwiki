import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// The live activity feed for an ACP-driven agent run — the "Agent Queue."
/// Shows a real-time transcript of agent tool calls, diagnostics, and results
/// as the agent executes, with an optional internals toggle for verbose output.
struct AgentQueueView: View {
    /// The daemon-mirrored chat session (replaces the in-process chat
    /// `AgentLauncher` after Phase C4). Run-state reads (`events`,
    /// `preflightError`, `stderr`, `isRunning`, `runningKind`) come from the
    /// daemon's live launcher via chat envelopes.
    var remoteSession: RemoteChatSession
    let showsResultEvents: Bool
    let showsInternals: Bool
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives and threaded down; `nil` when navigation is
    /// impossible (links still render, just don't navigate).
    var onWikiLink: ((URL, Bool) -> Void)? = nil

    init(remoteSession: RemoteChatSession, showsResultEvents: Bool = true, showsInternals: Bool = false, onWikiLink: ((URL, Bool) -> Void)? = nil) {
        self.remoteSession = remoteSession
        self.showsResultEvents = showsResultEvents
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
        // Selection + copy across the whole feed now happens inside
        // `ChatWebView`'s single document; this only covers the
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
            ChatWebView(events: renderedEvents, style: .activityFeed, showsInternals: showsInternals, onWikiLink: onWikiLink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsPlaceholder: Bool {
        renderedEvents.isEmpty && remoteSession.preflightError == nil
    }

    private var renderedEvents: [AgentEvent] {
        remoteSession.events.filter { event in
            if !showsInternals && event.isInternalTranscriptEvent {
                return false
            }
            if case .result = event {
                return showsResultEvents
            }
            return true
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if remoteSession.isRunning {
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


