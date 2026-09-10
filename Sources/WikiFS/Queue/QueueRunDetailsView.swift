import SwiftUI

/// The Run Details inspector panel — the selected job's labeled run facts in
/// an optional trailing panel inside the detail column (plan §1's fact list:
/// "enqueue/start/finish time, duration, attempt, actual provider/model,
/// usage and cost"). The panel's open/close lives in the window toolbar's
/// labeled toggle; this view is only the panel's content, so facts render
/// expanded — there is no secondary disclosure inside the panel.
///
/// Values come pre-mapped in `QueueRunDetailsFacts`; the omit-vs-"Not
/// Reported" rules live in `QueueRunDetailsFacts.entries` and are covered by
/// pure tests. The capacity bucket must never arrive as `providerText` — that
/// is the caller's mapping responsibility, documented on the field.
///
/// Facts render as a native List of labeled rows (not a bare Grid) so the
/// panel scrolls, rows stay a stable height, and hosted layout tests can
/// assert through the bridged `NSTableView` row count.
struct QueueRunDetailsView: View {
    /// The selected job's run facts; `nil` renders the panel's empty state
    /// (legacy jobs with nothing recorded).
    private let facts: QueueRunDetailsFacts?

    init(_ facts: QueueRunDetailsFacts?) {
        self.facts = facts
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            factsRegion
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run Details")
    }

    /// The panel's quiet header — names the surface for VoiceOver and for
    /// the window's visual hierarchy (the toolbar toggle controls it).
    private var panelHeader: some View {
        HStack(spacing: QueueWorkspaceMetrics.Spacing.sm) {
            Text("Run Details")
                .font(.headline)
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
    }

    @ViewBuilder
    private var factsRegion: some View {
        if let facts {
            entriesList(facts)
        } else {
            ContentUnavailableView {
                Label("No Run Details", systemImage: "info.circle")
            } description: {
                Text("Nothing recorded for this job.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Labeled values in a native List: secondary labels, selectable values,
    /// placeholders ("Not Reported") in tertiary so absent facts never read
    /// as reported ones. The job id row renders fully monospaced (a copyable
    /// identifier); every other value — timestamps, token counts, cost —
    /// stays monospaced-digit so numbers align without letter-spacing the
    /// text. Usage is one labeled row per present field (Input / Output /
    /// Cached / Thought / Cost), so every row carries its own label.
    private func entriesList(_ facts: QueueRunDetailsFacts) -> some View {
        List {
            ForEach(Array(facts.entries.enumerated()), id: \.offset) { _, entry in
                LabeledContent {
                    Text(entry.value)
                        .font(entry.isMonospaced
                            ? Font.callout.monospaced()
                            : Font.callout.monospacedDigit())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(
                            entry.isPlaceholder
                                ? Color(nsColor: .tertiaryLabelColor)
                                : Color.primary)
                } label: {
                    Text(verbatim: entry.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.label)
            }
        }
        .listStyle(.plain)
        .accessibilityLabel("Run Details facts")
    }
}
