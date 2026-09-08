import SwiftUI

/// The selected job's Run Details disclosure — labeled run facts below the
/// summary/content boundary (plan §1: "Run Details is a disclosure below the
/// summary/content boundary. Use labeled values for enqueue/start/finish time,
/// duration, attempt, actual provider/model, usage and cost").
///
/// Values come pre-mapped in `QueueRunDetailsFacts`; the omit-vs-"Not Reported"
/// rules live in `QueueRunDetailsFacts.entries` and are covered by pure tests.
/// The capacity bucket must never arrive as `providerText` — that is the
/// caller's mapping responsibility, documented on the field.
struct QueueRunDetailsView: View {
    private let facts: QueueRunDetailsFacts
    @State private var isExpanded = false

    init(_ facts: QueueRunDetailsFacts) {
        self.facts = facts
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            entriesGrid
                .padding(.top, QueueWorkspaceMetrics.Spacing.xs)
        } label: {
            Text("Run Details")
                .font(.headline)
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
    }

    /// Labeled values in a native grid: secondary labels, selectable values,
    /// placeholders ("Not Reported") in tertiary so absent facts never read as
    /// reported ones.
    private var entriesGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: QueueWorkspaceMetrics.Spacing.sm, verticalSpacing: 4) {
            ForEach(Array(facts.entries.enumerated()), id: \.offset) { _, entry in
                GridRow(alignment: .firstTextBaseline) {
                    Text(verbatim: entry.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(entry.value)
                        .font(.callout)
                        .foregroundStyle(entry.isPlaceholder ? Color(nsColor: .tertiaryLabelColor) : Color.primary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.label.isEmpty ? "Usage" : entry.label)
            }
        }
    }
}
