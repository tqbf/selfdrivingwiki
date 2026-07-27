import SwiftUI

/// Inspector-body content for the chat surface's outline.
struct ChatInspectorOutlineView: View {
    let entries: [ChatOutlineEntry]
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    Button {
                        onSelect(index)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            if let ts = entry.questionTimestamp {
                                Text(ts, format: .dateTime.hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.bottom, 2)
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text("•")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.question.isEmpty ? "(empty)" : entry.question)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                            }
                            if let response = entry.response {
                                HStack(alignment: .top, spacing: 4) {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(response)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
    }
}
