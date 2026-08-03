import SwiftUI
import WikiFSCore

/// A sheet-based replacement for a plain `.alert` when surfacing
/// `WikiStoreModel.storeError`. `.alert` renders as a system `NSAlert` on
/// macOS, which clamps to a narrow fixed width — a message listing several
/// skipped duplicate filenames wraps into an unreadably narrow column. This
/// sheet gives the message room to breathe and scrolls if the list is long.
///
/// Follows `ImportMarkdownSheet`'s metrics-enum + fixed-width pattern.
struct StoreErrorSheet: View {
    let error: WikiStoreModel.StoreError
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ScrollView {
                Text(error.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metrics.maxMessageHeight)
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .onExitCommand { dismiss() }
    }

    private enum Metrics {
        static let width: CGFloat = 480
        static let padding: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
        static let maxMessageHeight: CGFloat = 320
    }
}
