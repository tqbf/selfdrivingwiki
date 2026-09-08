import SwiftUI

// MARK: - Hosted-test expansion pin

/// Pins the Run Details disclosure laid out as expanded when set. Hosted
/// layout tests inject it at the window root (`ActivityWindowView` forwards
/// a corresponding flag into the environment) so the expanded state can be
/// driven through the real tree — the same layout the disclosure's own
/// toggle produces. Production never sets it, so the disclosure's toggle
/// stays the only writer of its state; the pin only reads.
private struct QueueRunDetailsPinnedExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` keeps the Run Details disclosure laid out as expanded. See
    /// ``QueueRunDetailsPinnedExpandedKey`` — hosted layout tests only.
    var queueRunDetailsPinnedExpanded: Bool {
        get { self[QueueRunDetailsPinnedExpandedKey.self] }
        set { self[QueueRunDetailsPinnedExpandedKey.self] = newValue }
    }
}

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
    @Environment(\.queueRunDetailsPinnedExpanded) private var pinnedExpanded

    init(_ facts: QueueRunDetailsFacts) {
        self.facts = facts
    }

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            // The disclosure is pinned below the inventory List inside the
            // Overview's non-scrolling VStack, so its expanded demand must be
            // bounded: `entriesGrid` alone reports a fixed ideal height, which
            // starves the flexible List to zero height (the blank workspace
            // pane) and can push the workspace's ideal height past the window
            // — which also collapses the sidebar's window-toolbar inset (#835).
            // The ScrollView makes the region content-sized; the ceiling caps
            // the demand, and taller grids scroll inside it instead of growing it.
            ScrollView {
                entriesGrid
                    .padding(.top, QueueWorkspaceMetrics.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: QueueWorkspaceMetrics.RunDetails.maxExpandedHeight)
        } label: {
            Text("Run Details")
                .font(.headline)
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
    }

    /// The disclosure's expansion binding: its own toggle state, OR the
    /// hosted-test pin. The pin never writes state during view updates — it
    /// only forces the expanded layout while set.
    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { isExpanded || pinnedExpanded },
            set: { isExpanded = $0 })
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
