import SwiftUI
import WikiFSCore

/// Sheet for editing a bookmark's name (label). Works for folders, page refs,
/// and source refs. Shows the target info read-only for refs.
struct EditBookmarkSheet: View {
    let store: WikiStoreModel
    let nodeID: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    private var node: BookmarkNode? {
        store.bookmarkNodes.first { $0.id == nodeID }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(node?.kind == .folder ? "Edit Folder" : "Edit Bookmark")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)

                if let node, node.kind != .folder {
                    if let target = node.targetID.flatMap({ id in
                        store.summaries.first { $0.id == id }
                    }) {
                        Text("Points to page: \(target.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let target = node.targetID.flatMap({ id in
                        store.sources.first { $0.id == id }
                    }) {
                        Text("Points to source: \(target.effectiveName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack {
                if node?.kind != .folder, node?.label != nil {
                    Button("Reset Name") {
                        let fallback: String
                        if let n = node, n.kind == .pageRef {
                            fallback = n.targetID.flatMap { id in
                                store.summaries.first { $0.id == id }?.title
                            } ?? ""
                        } else {
                            fallback = node?.targetID.flatMap { id in
                                store.sources.first { $0.id == id }?.effectiveName
                            } ?? ""
                        }
                        name = fallback
                    }
                    .buttonStyle(.bordered)
                }

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
        .frame(width: 340, height: 200)
        .onAppear {
            name = node?.label ?? ""
        }
    }
}
