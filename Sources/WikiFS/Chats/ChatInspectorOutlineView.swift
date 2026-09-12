import SwiftUI
import WikiFSCore

/// Inspector-body content for the chat surface's outline.
struct ChatInspectorOutlineView: View {
    let entries: [ChatOutlineEntry]
    let onSelect: (ChatOutlineEntry.ID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.id) { entry in
                    outlineRow(entry)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// One outline entry. The row action is a tap gesture rather than a
    /// Button on purpose: a Button's press gesture swallows drag events, so
    /// drag-to-select on the entry texts could never engage. With a tap
    /// gesture, a click still jumps to the turn while a drag selects text.
    private func outlineRow(_ entry: ChatOutlineEntry) -> some View {
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
                    .textSelection(.enabled)
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
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(entry.id) }
        .contextMenu {
            Button("Copy Question") {
                _ = MetadataActionRouter.systemClipboardCopy(entry.question)
            }
            if let response = entry.response {
                Button("Copy Response") {
                    _ = MetadataActionRouter.systemClipboardCopy(response)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(entry.id) }
    }
}
