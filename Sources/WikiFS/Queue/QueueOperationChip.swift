import SwiftUI

/// A compact label that identifies a queue job's operation without changing
/// the job title. The neutral style keeps lifecycle colors authoritative.
struct QueueOperationChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Operation: \(label)")
    }
}
