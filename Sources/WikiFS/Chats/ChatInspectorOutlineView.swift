import SwiftUI

/// Inspector-body content for the chat surface's outline.
struct ChatInspectorOutlineView: View {
    let entries: [ChatOutlineEntry]
    let onSelect: (ChatOutlineEntry.ID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.id) { entry in
                    Button {
                        onSelect(entry.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            if let ts = entry.questionTimestamp {
                                Text(ts, format: .dateTime.hour().minute())
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.bottom, 2)
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text("•")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                Text(entry.question.isEmpty ? "(empty)" : entry.question)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                            }
                            if let response = entry.response {
                                HStack(alignment: .top, spacing: 4) {
                                    Text("•")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Text(response)
                                        .font(.system(size: 13))
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
