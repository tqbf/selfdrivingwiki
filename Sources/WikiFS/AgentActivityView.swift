import SwiftUI
import WikiFSCore

/// The live activity feed for a `claude -p` run. This is the inspector/log
/// surface: compact rows, tool calls, diagnostics, and optional internals.
struct AgentActivityView: View {
    @Bindable var launcher: AgentLauncher
    let showsResultEvents: Bool
    let showsInternals: Bool

    init(launcher: AgentLauncher, showsResultEvents: Bool = true, showsInternals: Bool = false) {
        self.launcher = launcher
        self.showsResultEvents = showsResultEvents
        self.showsInternals = showsInternals
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
            activityList
            if showsInternals && !launcher.stderr.isEmpty {
                stderrBanner
            }
        }
        // Enable selection + copy across the whole feed (propagates to every
        // descendant `Text` via environment). StructuredText (AgentMarkdownText)
        // selects via its own `.textual.textSelection`.
        .textSelection(.enabled)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var activityList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ActivityMetrics.rowSpacing) {
                    if showsPlaceholder {
                        placeholder
                    } else {
                        ForEach(renderedEvents, id: \.offset) { _, event in
                            AgentEventRow(event: event)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(ActivityMetrics.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: launcher.events.count) {
                withAnimation(.linear(duration: 0.12)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private var showsPlaceholder: Bool {
        renderedEvents.isEmpty && launcher.preflightError == nil
    }

    private var renderedEvents: [(offset: Int, element: AgentEvent)] {
        launcher.events.enumerated().filter { _, event in
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

    private static let bottomAnchor = "agent-activity-bottom"
}

private struct AgentEventRow: View {
    let event: AgentEvent

    var body: some View {
        switch event {
        case .userText(let text):
            userRow(text: text)
        case .systemInit(let model):
            metaRow(symbol: "sparkles", text: "Started · \(model)")
        case .assistantText(let text):
            AgentMarkdownText(markdown: text)
        case .toolUse(let name, let inputSummary):
            toolRow(name: name, summary: inputSummary)
        case .toolResult(let isError, let summary):
            toolResultRow(isError: isError, summary: summary)
        case .subagent(let subagentType, let description, let isCompletion):
            subagentRow(subagentType: subagentType, description: description, isCompletion: isCompletion)
        case .result(let isError, let text):
            resultRow(isError: isError, text: text)
        case .raw(let line):
            Text(line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userRow(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("You", systemImage: "person.crop.circle")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func metaRow(symbol: String, text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func toolRow(name: String, summary: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(forTool: name))
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func subagentRow(subagentType: String, description: String, isCompletion: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isCompletion ? "checkmark.circle" : "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(isCompletion ? Color.green : Color.purple)
                .frame(width: 16)
            Text(subagentType)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.purple)
            Text(isCompletion ? "digested" : "reading")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private func toolResultRow(isError: Bool, summary: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
                .frame(width: 16)
            Text(summary.isEmpty ? (isError ? "(error)" : "(ok)") : summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(3)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func resultRow(isError: Bool, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(isError ? "Failed" : "Result", systemImage: isError ? "exclamationmark.octagon.fill" : "checkmark.seal.fill")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(isError ? .red : .green)
            if !text.isEmpty {
                AgentMarkdownText(markdown: text)
            }
        }
        .padding(.vertical, 4)
    }

    private func symbol(forTool name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit": return "pencil"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Agent", "Task": return "person.2.fill"
        default: return "wrench.and.screwdriver"
        }
    }
}

private enum ActivityMetrics {
    static let padding: CGFloat = 10
    static let rowSpacing: CGFloat = 8
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
