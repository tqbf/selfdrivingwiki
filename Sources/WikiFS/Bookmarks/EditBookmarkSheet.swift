import SwiftUI
import WikiFSCore

/// Sheet for editing a bookmark folder's name.
struct EditBookmarkSheet: View {
    let store: WikiStoreModel
    let nodeID: BookmarkID
    /// Receives the chosen folder name. Main-actor: the caller touches the
    /// @MainActor WikiStoreModel to create bookmark refs.
    let onSave: (@MainActor @Sendable (String) -> Void)

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    private var node: BookmarkNode? {
        store.bookmarkNodes.first { $0.id == nodeID }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Folder")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)

                // Timestamps (read-only) — issue #242. Relative date mirrors
                // ChatsCellView's treatment of chat.updatedAt; the absolute date
                // is the tooltip for precision. "Updated" only appears when the
                // node has actually changed since creation.
                if let node {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Added \(node.createdAt, format: .relative(presentation: .named))")
                            .help(node.createdAt.formatted(.dateTime))
                        if node.updatedAt > node.createdAt {
                            Text("Updated \(node.updatedAt, format: .relative(presentation: .named))")
                                .help(node.updatedAt.formatted(.dateTime))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onSave(trimmed)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340, height: 240)
        .onAppear {
            name = node?.label ?? ""
        }
    }
}
