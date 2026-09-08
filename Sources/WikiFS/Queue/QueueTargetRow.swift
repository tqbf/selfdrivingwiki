import SwiftUI

/// The shared target-inventory row for the Overview list — every payload
/// source/page (and whole-wiki scope rows) renders through this one component
/// so both queue windows present targets identically (plan §1 "Overview
/// inventory").
///
/// Wide windows align a Name column against a State/Result column; narrow
/// windows stack them instead of competing for width. Disclosing a row reveals
/// the full selectable name, typed identity, reason, and available actions
/// inline — a tooltip is never the only full-name surface.
///
/// The row reads only the immutable `QueueTargetRowValue` plus its own
/// expansion flag; the enclosing list precomputes values before iteration, so
/// no `@Observable` reads happen inside row bodies (observation-crash
/// workaround stays valid).
struct QueueTargetRow: View {
    private let value: QueueTargetRowValue
    private let isExpanded: Bool
    private let onToggleExpanded: () -> Void

    /// - Parameters:
    ///   - value: Precomputed row display value.
    ///   - isExpanded: Whether the full-name/reason/actions block shows.
    ///   - onToggleExpanded: Invoked by the chevron or a tap on the collapsed
    ///     row background; the owner keeps the expansion set.
    init(
        value: QueueTargetRowValue,
        isExpanded: Bool,
        onToggleExpanded: @escaping () -> Void
    ) {
        self.value = value
        self.isExpanded = isExpanded
        self.onToggleExpanded = onToggleExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                alignedLayout
                stackedLayout
            }
            if isExpanded, value.hasDisclosableDetail {
                disclosedContent
            }
        }
        .padding(.vertical, QueueWorkspaceMetrics.Inventory.rowVerticalPadding)
    }

    // MARK: Collapsed layouts

    /// Wide: name left, status right — an aligned State/Result column.
    private var alignedLayout: some View {
        HStack(alignment: .center, spacing: QueueWorkspaceMetrics.Spacing.sm) {
            titleColumn
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
            statusColumn
            disclosureControl
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    /// Narrow: status above name, disclosure at the trailing edge.
    private var stackedLayout: some View {
        HStack(alignment: .top, spacing: QueueWorkspaceMetrics.Spacing.sm) {
            VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
                statusColumn
                titleColumn
            }
            Spacer(minLength: 0)
            disclosureControl
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    /// The target's name, wrapping to two lines before truncating (plan: long
    /// names wrap to two lines). Scope rows ("Whole wiki") render the same way
    /// as real targets.
    private var titleColumn: some View {
        Text(value.title)
            .font(.body)
            .lineLimit(QueueWorkspaceMetrics.Inventory.titleLineLimit)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(value.title)
    }

    /// State/Result cell: symbol + text in the status's semantic style.
    private var statusColumn: some View {
        Label(value.status.text, systemImage: value.status.symbol)
            .font(.callout)
            .foregroundStyle(color(for: value.status.style))
            .accessibilityLabel("\(value.title): \(value.status.text)")
    }

    /// Chevron disclosure. Hidden entirely for rows with nothing to reveal
    /// (no full name, reason, identity, or actions).
    @ViewBuilder
    private var disclosureControl: some View {
        if value.hasDisclosableDetail {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(isExpanded ? "Hide details for \(value.title)" : "Show details for \(value.title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help(isExpanded ? "Hide details" : "Show full name and details")
        }
    }

    // MARK: Disclosed content

    /// Full selectable name, typed identity, reason, and available actions —
    /// everything the collapsed row truncates or hides.
    private var disclosedContent: some View {
        VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
            if let fullName = value.fullName {
                Text(fullName)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let identity = value.identity {
                Text(verbatim: identity.rowID)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityLabel("\(identityLabel(identity)) identifier")
            }
            if let reason = value.reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !value.actions.isEmpty {
                HStack(spacing: QueueWorkspaceMetrics.Spacing.xs) {
                    ForEach(Array(value.actions.enumerated()), id: \.offset) { _, action in
                        Button {
                            action.perform()
                        } label: {
                            Label(action.label, systemImage: action.systemImage)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(action.label)
                    }
                }
            }
        }
        .padding(.leading, QueueWorkspaceMetrics.Inventory.disclosedIndent)
    }

    private func toggle() {
        onToggleExpanded()
    }

    private func identityLabel(_ identity: QueueWorkspaceTargetIdentity) -> String {
        switch identity {
        case .source: return "Source"
        case .page: return "Page"
        }
    }

    /// Semantic style → foreground style, resolved in exactly one place.
    /// Running keeps full emphasis; everything else uses the semantic color or
    /// recedes so failures stay the loudest thing in the inventory.
    private func color(for style: QueueWorkspaceStatus.Style) -> Color {
        switch style {
        case .primary: return .primary
        case .secondary: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        case .running: return .primary
        }
    }
}
