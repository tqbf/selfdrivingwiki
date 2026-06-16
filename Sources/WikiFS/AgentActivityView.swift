import AppKit
import SwiftUI
import WikiFSCore

/// The live activity feed for a `claude -p` run (`plans/llm-wiki.md` Phase C). Turns
/// the launcher's typed `events` into a readable, auto-scrolling list — each tool
/// call a monospaced row (SF Symbol + name + concise input summary), assistant text
/// as prose, and the final result distinctly styled (success vs error). Replaces the
/// old "raw blob" console so a run no longer looks like it's doing nothing.
///
/// SWIFTUI-RULES: §1.1 — auto-scroll animates a scroll offset, never inserts/removes
/// a structural view; rows are identified by stable index so appends don't reflow the
/// world. §5.1 — semantic fonts throughout (`.callout` prose, monospaced `.caption`
/// for tool/code, consistent type scale). macos-design — a clean native panel.
struct AgentActivityView: View {
    @Bindable var launcher: AgentLauncher

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = launcher.preflightError {
                preflightBanner(error)
            }
            activityList
            if !launcher.stderr.isEmpty {
                stderrBanner
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Activity list

    private var activityList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ActivityMetrics.rowSpacing) {
                    if showsPlaceholder {
                        placeholder
                    } else {
                        ForEach(Array(launcher.events.enumerated()), id: \.offset) { _, event in
                            AgentEventRow(event: event)
                        }
                    }
                    // Zero-height anchor we scroll to; appending events grows the list
                    // above it, so scrolling here keeps the newest line in view without
                    // any structural insert/remove of the anchor itself (§1.1).
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
        launcher.events.isEmpty && launcher.preflightError == nil
    }

    @ViewBuilder
    private var placeholder: some View {
        if launcher.isRunning {
            // Run started but no events yet — show the spinner so the panel is never
            // "staring at nothing".
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(launcher.runningKind.map { "Starting \($0.title)…" } ?? "Starting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No activity yet. Choose an operation and press Run.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Banners

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
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ActivityMetrics.padding)
        .background(.orange.opacity(0.10))
    }

    // MARK: - Constants

    private static let bottomAnchor = "agent-activity-bottom"
}

/// One row of the activity feed, switched on the event kind. A small dedicated view
/// so SwiftUI scopes redraws to the changed rows (§3.1 rebuild-from-source: each row
/// derives purely from its `AgentEvent`).
private struct AgentEventRow: View {
    let event: AgentEvent

    var body: some View {
        switch event {
        case .systemInit(let model):
            metaRow(symbol: "sparkles", text: "Started · \(model)")

        case .assistantText(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

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
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    /// A subagent fan-out row: the Opus curator delegating to (or hearing back from)
    /// a Sonnet `source-reader` digester. Indented + tinted so the fan-out reads as a
    /// distinct nested activity, making the Opus→Sonnet hand-off visible in the panel.
    /// The Sonnet workers READ source volume and return digests; the rows are labelled
    /// "reading" / "digested" to reflect that they do not write the wiki.
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
                    .textSelection(.enabled)
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
                .textSelection(.enabled)
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
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// An SF Symbol per tool kind so the feed scans visually.
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

/// Layout constants for the activity feed (§2.4 — no scattered magic numbers).
private enum ActivityMetrics {
    static let padding: CGFloat = 10
    static let rowSpacing: CGFloat = 8
}
