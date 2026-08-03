import SwiftUI
import WikiFSCore

/// Sheet for editing a bookmark: folders rename in place, while leaf
/// references retarget to a different page/source/chat.
struct EditBookmarkSheet: View {
    enum SaveActionResult: Equatable {
        case dismiss
        case showError(String)
    }

    private enum RetargetSelection: Hashable {
        case page(PageID)
        case source(SourceID)
        case chat(ChatID)

        var content: BookmarkNode.Content {
            switch self {
            case .page(let id): .page(id)
            case .source(let id): .source(id)
            case .chat(let id): .chat(id)
            }
        }
    }

    private struct RetargetOption: Identifiable, Hashable {
        let selection: RetargetSelection
        let title: String

        var id: RetargetSelection { selection }
    }

    let store: WikiStoreModel
    let nodeID: BookmarkID

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var selectedTarget: RetargetSelection?
    @State private var errorMessage: String?

    private var node: BookmarkNode? {
        store.bookmarkNodes.first { $0.id == nodeID }
    }

    private var titleText: String {
        guard let node else { return "Edit Bookmark" }
        switch node.content {
        case .folder:
            return "Edit Folder"
        case .page:
            return "Edit Page Bookmark"
        case .source:
            return "Edit Source Bookmark"
        case .chat:
            return "Edit Chat Bookmark"
        }
    }

    private var saveDisabled: Bool {
        guard let node else { return true }
        switch node.content {
        case .folder:
            return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .page, .source, .chat:
            return selectedTarget == nil
        }
    }

    private var retargetOptions: [RetargetOption] {
        guard let node else { return [] }
        switch node.content {
        case .folder:
            return []
        case .page:
            return store.summaries.map {
                RetargetOption(selection: .page($0.id), title: $0.title)
            }
        case .source:
            return store.sources.map {
                RetargetOption(selection: .source($0.id), title: $0.effectiveName)
            }
        case .chat:
            return store.chats.map {
                RetargetOption(selection: .chat($0.id), title: $0.title)
            }
        }
    }

    static func saveAction(
        node: BookmarkNode?,
        name: String,
        selectedTarget: BookmarkNode.Content?,
        renameFolder: (String) throws -> Void,
        retargetBookmark: (BookmarkNode.Content) throws -> Void
    ) -> SaveActionResult? {
        guard let node else {
            return .dismiss
        }

        switch node.content {
        case .folder:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            do {
                try renameFolder(trimmed)
                return .dismiss
            } catch {
                return .showError(error.localizedDescription)
            }
        case .page, .source, .chat:
            guard let selectedTarget else { return nil }
            do {
                try retargetBookmark(selectedTarget)
                return .dismiss
            } catch {
                return .showError(error.localizedDescription)
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(titleText)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                switch node?.content {
                case .folder:
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                case .page, .source, .chat:
                    Text("Target")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Target", selection: $selectedTarget) {
                        ForEach(retargetOptions) { option in
                            Text(option.title).tag(Optional(option.selection))
                        }
                    }
                    .pickerStyle(.menu)
                case nil:
                    EmptyView()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

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
                    errorMessage = nil
                    switch Self.saveAction(
                        node: node,
                        name: name,
                        selectedTarget: selectedTarget?.content,
                        renameFolder: { try store.renameBookmarkNode(id: nodeID, to: $0) },
                        retargetBookmark: { try store.retargetBookmarkNode(id: nodeID, to: $0) }
                    ) {
                    case .dismiss?:
                        dismiss()
                    case .showError(let message)?:
                        errorMessage = message
                    case nil:
                        break
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saveDisabled)
            }
        }
        .padding(20)
        .frame(width: 340, height: 240)
        .onAppear {
            guard let node else { return }
            switch node.content {
            case .folder:
                name = node.label ?? ""
            case .page(let id):
                selectedTarget = .page(id)
            case .source(let id):
                selectedTarget = .source(id)
            case .chat(let id):
                selectedTarget = .chat(id)
            }
        }
    }
}
