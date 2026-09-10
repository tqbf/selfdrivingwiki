import SwiftUI

/// The shared target-inventory row for the Overview list — every payload
/// source/page (and whole-wiki scope rows) renders through this one component
/// so both queue windows present targets identically (plan §1 "Overview
/// inventory").
///
/// The row is NOT collapsible: it shows the target name and — when the
/// target carries a real recorded state — its state/result chip, nothing
/// else. Evidence-less rows (`QueueTargetRowValue.status == nil`,
/// operator decision 2026-09-09) render name-only: "Planned" is the
/// default state, so it gets no circle and no text. Typed identity
/// (SourceID/PageID) is never rendered — the
/// name is the surface. When the target carries a live navigation action, the
/// The NAME ITSELF is the link (native `.link` button style) performing it —
/// "Open Page" for pages, "Reveal Source" for sources, "Browse Pages" for
/// whole-wiki scope rows. Dead targets keep their recorded name as plain
/// text: the caller omits actions when a recorded output reference no longer
/// resolves, so a dead link never renders. Routing stays the caller's
/// `QueueWorkspaceAction` closures (`openPage` / `revealSource` /
/// `browsePages`).
///
/// Wide windows align the Name column against a State/Result column; narrow
/// windows stack them instead of competing for width.
///
/// The row reads only the immutable `QueueTargetRowValue`; the enclosing list
/// precomputes values before iteration, so no `@Observable` reads happen
/// inside row bodies (observation-crash workaround stays valid).
struct QueueTargetRow: View {
    private let value: QueueTargetRowValue

    /// - Parameter value: Precomputed row display value. Its `actions` (at
    ///   most one in practice) carry the target's live navigation; the first
    ///   becomes the name link.
    init(value: QueueTargetRowValue) {
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            alignedLayout
            stackedLayout
        }
        .padding(.vertical, QueueWorkspaceMetrics.Inventory.rowVerticalPadding)
    }

    // MARK: Layouts

    /// Wide: name left, status right — an aligned State/Result column.
    private var alignedLayout: some View {
        HStack(alignment: .center, spacing: QueueWorkspaceMetrics.Spacing.sm) {
            nameColumn
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
            statusColumn
        }
    }

    /// Narrow: status above name — the pair stacks instead of competing for
    /// width.
    private var stackedLayout: some View {
        HStack(alignment: .top, spacing: QueueWorkspaceMetrics.Spacing.sm) {
            VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
                statusColumn
                nameColumn
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Columns

    /// The target's name. With a live action it is a native link performing
    /// that action; without one (dead/unresolvable target, no navigation) it
    /// is plain text. Names wrap to two lines before truncating (plan: long
    /// names wrap to two lines); the full recorded name stays one tooltip
    /// away. Scope rows ("Whole wiki") render the same way as real targets.
    @ViewBuilder
    private var nameColumn: some View {
        if let action = value.actions.first {
            Button {
                action.perform()
            } label: {
                titleText
            }
            .buttonStyle(.link)
            .help("\(action.label): \(value.displayName)")
            .accessibilityHint(action.label)
        } else {
            titleText
                .help(value.displayName)
        }
    }

    private var titleText: some View {
        Text(value.title)
            .font(.body)
            .lineLimit(QueueWorkspaceMetrics.Inventory.titleLineLimit)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(value.title)
    }

    /// State/Result cell: symbol + text in the status's semantic style.
    /// Evidence-less rows (`status == nil`, operator decision 2026-09-09:
    /// "Planned" is the default state, so labeling it communicates nothing)
    /// render NO status region at all — the row is name-only, and no empty
    /// status element ever reaches the accessibility tree.
    @ViewBuilder
    private var statusColumn: some View {
        if let status = value.status {
            Label(status.text, systemImage: status.symbol)
                .font(.callout)
                .foregroundStyle(color(for: status.style))
                .accessibilityLabel("\(value.title): \(status.text)")
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
