import SwiftUI
import WikiFSCore

/// The pending batch behind the re-ingest confirmation sheet: the ids to
/// enqueue on confirm, plus the display names of the already-ingested
/// sources. One typed value replaces the former parallel
/// bool + id-array + name-array state triple.
struct ReingestConfirmation: Identifiable, Equatable {
    /// Fresh identity per presentation, so re-confirming a second batch
    /// re-presents the sheet.
    let id = UUID()
    let sourceIDs: [SourceID]
    let alreadyIngestedNames: [String]
}

/// Confirmation sheet for re-ingesting sources that were already ingested.
///
/// House rule: a dialog that takes a list must render that list in a table
/// with its own scrollbar. The former `.confirmationDialog` inlined every
/// already-ingested name into its message `Text`, so a large selection (85
/// sources) grew the dialog past the screen and the buttons fell out of
/// reach. This sheet bounds the name table to a fixed height range — it
/// scrolls independently — and keeps the buttons visible below it.
///
/// The table is a `ScrollView` + `LazyVStack` (the `ExtractionCompareSheet`
/// pattern), not a `List`: `List` reports no content height inside a sheet,
/// so it collapsed to zero and rendered no rows.
///
/// Follows `StoreErrorSheet`'s metrics-enum + fixed-width pattern; type roles
/// match the app's other utility sheets (`.headline` title, `.body` secondary
/// message, `.callout` footnote).
struct ReingestConfirmationSheet: View {
    let confirmation: ReingestConfirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            Label("Ingest Again?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(alreadyIngestedHeadline)
                .font(.body)
                .foregroundStyle(.secondary)
            if !confirmation.alreadyIngestedNames.isEmpty {
                table
            }
            Text("Running ingest again may create duplicate pages.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Ingest Again", role: .destructive) { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .onExitCommand { onCancel() }
    }

    /// The bounded, self-scrolling table of already-ingested names.
    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(
                    Array(confirmation.alreadyIngestedNames.enumerated()),
                    id: \.offset
                ) { _, name in
                    row(name)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.tableCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.tableCornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .frame(minHeight: Metrics.minTableHeight, maxHeight: Metrics.maxTableHeight)
    }

    private func row(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .padding(.horizontal, Metrics.rowPadding)
                .padding(.vertical, Metrics.rowPadding / 2)
            Divider().opacity(0.4)
        }
    }

    /// "The following 3 sources have already been ingested:" — the count is
    /// the summary; the names live in the table, not the prose.
    private var alreadyIngestedHeadline: String {
        let count = confirmation.alreadyIngestedNames.count
        let noun = count == 1 ? "source has" : "sources have"
        return "The following \(count) \(noun) already been ingested:"
    }

    private enum Metrics {
        static let width: CGFloat = 480
        static let padding: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
        static let tableCornerRadius: CGFloat = 6
        static let rowPadding: CGFloat = 12
        /// The table always shows as a table: short lists get a visible
        /// area, long lists stop at the cap and scroll.
        static let minTableHeight: CGFloat = 96
        static let maxTableHeight: CGFloat = 320
    }
}
