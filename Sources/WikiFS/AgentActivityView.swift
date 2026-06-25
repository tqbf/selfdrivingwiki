import SwiftUI
import WikiFSCore

/// The live activity feed for a `claude -p` run. This is the inspector/log
/// surface: compact rows, tool calls, diagnostics, and optional internals.
struct AgentActivityView: View {
    @Bindable var launcher: AgentLauncher
    let showsResultEvents: Bool
    let showsInternals: Bool
    /// Forwards wiki-link clicks in the transcript to the detail column. Built
    /// where the store lives and threaded down; `nil` when navigation is
    /// impossible (links still render, just don't navigate).
    var onWikiLink: ((URL) -> Void)? = nil

    init(launcher: AgentLauncher, showsResultEvents: Bool = true, showsInternals: Bool = false, onWikiLink: ((URL) -> Void)? = nil) {
        self.launcher = launcher
        self.showsResultEvents = showsResultEvents
        self.showsInternals = showsInternals
        self.onWikiLink = onWikiLink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = launcher.preflightError {
                preflightBanner(error)
            }
            if showsInternals {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    AgentRunStatusView(launcher: launcher, now: context.date)
                        .padding(.horizontal, ActivityMetrics.padding)
                        .padding(.top, ActivityMetrics.padding)
                }
            }
            activityFeed
            if showsInternals && !launcher.stderr.isEmpty {
                stderrBanner
            }
        }
        // Selection + copy across the whole feed now happens inside
        // `AgentTranscriptWebView`'s single document; this only covers the
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
            AgentTranscriptWebView(events: renderedEvents, style: .activityFeed, showsInternals: showsInternals, onWikiLink: onWikiLink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsPlaceholder: Bool {
        renderedEvents.isEmpty && launcher.preflightError == nil
    }

    private var renderedEvents: [AgentEvent] {
        launcher.events.filter { event in
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
        if launcher.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(showsInternals ? (launcher.runningKind.map { "Starting \($0.title)…" } ?? "Starting…") : "Waiting for output…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(showsInternals ? "No activity yet. Choose an operation and press Run." : "No output yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
            Text(launcher.stderr)
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

extension AgentEvent {
    var isInternalTranscriptEvent: Bool {
        switch self {
        case .systemInit, .toolUse, .toolResult, .subagent, .raw:
            true
        case .userText, .assistantText, .result:
            false
        }
    }
}
