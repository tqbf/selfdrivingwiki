import SwiftUI

enum MetadataMetrics {
    /// Hosted layout tests establish 300 points as the smallest inspector width
    /// that keeps labels, values, and accessible actions readable side-by-side.
    static let stackedRowThreshold: CGFloat = 300
    static let minimumWidth: CGFloat = 180
    static let maximumWidth: CGFloat = 500
}

enum MetadataLayout {
    static func usesStackedRows(for width: CGFloat) -> Bool {
        width < MetadataMetrics.stackedRowThreshold
    }
}

struct MetadataPanelView: View {
    let state: MetadataHydrationState
    let width: CGFloat
    let performAction: (MetadataActionTarget) -> Void
    let openLink: (MetadataLinkTarget) -> Void

    private var usesStackedRows: Bool { MetadataLayout.usesStackedRows(for: width) }

    var body: some View {
        ScrollView {
            switch state {
            case .idle, .loading:
                ProgressView("Loading metadata")
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .failed(_, let message):
                ContentUnavailableView("Metadata unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .loaded(let model):
                if model.emptyState == .unavailable {
                    ContentUnavailableView("Metadata unavailable", systemImage: "info.circle")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.sections) { section in
                            metadataSection(section)
                            if section.id != model.sections.last?.id { Divider() }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .accessibilityIdentifier("metadata-panel")
        .accessibilityValue(usesStackedRows ? "stacked rows" : "grid rows")
    }

    @ViewBuilder private func metadataSection(_ section: MetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(section.rows) { row in
                if usesStackedRows {
                    VStack(alignment: .leading, spacing: 2) {
                        rowLabel(row)
                        rowValue(row)
                    }
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            rowLabel(row)
                            rowValue(row)
                        }
                    }
                }
            }
        }
    }

    private func rowLabel(_ row: MetadataRow) -> some View {
        Text(row.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(row.label)
    }

    @ViewBuilder private func rowValue(_ row: MetadataRow) -> some View {
        switch MetadataValueRenderer.presentation(for: row.value) {
        case .text(let text, let usesTabularDigits):
            formattedText(text, usesTabularDigits: usesTabularDigits, hint: row.accessibilityHint)
        case .identifier(let identifier):
            Text(identifier)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("metadata-identifier")
                .accessibilityLabel("\(row.label): \(identifier)")
                .accessibilityHint(row.accessibilityHint ?? "")
        case .link(let label, let target):
            Button(label) { openLink(target) }
                .buttonStyle(.link)
                .accessibilityHint(row.accessibilityHint ?? "Open linked item")
        case .action(let label, let target):
            Button(label) { performAction(target) }
                .buttonStyle(.link)
                .accessibilityHint(row.accessibilityHint ?? "Perform metadata action")
        }
    }

    @ViewBuilder private func formattedText(_ text: String, usesTabularDigits: Bool, hint: String?) -> some View {
        if usesTabularDigits {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .monospacedDigit()
                .accessibilityHint(hint ?? "")
        } else {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .accessibilityHint(hint ?? "")
        }
    }
}
