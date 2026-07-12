import Foundation
import WikiFSCore

/// The `wikictl bookmark …` subcommands, executed against an already-opened
/// `WikiStore`. Mirrors `ChatCommand` / `SourceCommand` — split from process
/// concerns (arg parsing, stdin, the Darwin post, opening the DB) so the whole
/// surface is unit-testable against a temp DB.
///
/// Read and write: `list` prints all bookmark nodes (TSV), `create-folder`,
/// `add-ref`, `rename`, `delete`, and `move` mutate the bookmark tree and
/// commit (the caller posts the Darwin notification on `didCommit`).
public enum BookmarkCommand {

    /// What a command produced: text to print and whether it COMMITTED a write.
    public struct Result: Equatable {
        public var output: String
        public var didCommit: Bool

        public init(output: String, didCommit: Bool) {
            self.output = output
            self.didCommit = didCommit
        }
    }

    public enum Action: Equatable {
        case list(json: Bool)
        case createFolder(parentID: String?, name: String)
        case addRef(parentID: String?, kind: BookmarkNodeKind, targetID: PageID)
        case rename(id: String, to: String)
        case delete(id: String)
        case move(id: String, toParentID: String?, position: Int)
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Run one action against `store`. Reads never commit; mutations do.
    public static func run(_ action: Action, in store: WikiStore) throws -> Result {
        switch action {
        case .list(let json):
            return try list(in: store, json: json)
        case .createFolder(let parentID, let name):
            return try createFolder(parentID: parentID, name: name, in: store)
        case .addRef(let parentID, let kind, let targetID):
            return try addRef(parentID: parentID, kind: kind, targetID: targetID, in: store)
        case .rename(let id, let newName):
            return try rename(id: id, to: newName, in: store)
        case .delete(let id):
            return try delete(id: id, in: store)
        case .move(let id, let toParentID, let position):
            return try move(id: id, toParentID: toParentID, position: position, in: store)
        }
    }

    // MARK: - list

    private static func list(in store: WikiStore, json: Bool) throws -> Result {
        let nodes = try store.listBookmarkNodes()
        if json {
            // Manual JSONL — BookmarkNode isn't Codable.
            let lines = nodes.map { node in
                let parent = node.parentID ?? ""
                let label = node.label ?? ""
                let target = node.targetID?.rawValue ?? ""
                return "{\"id\":\"\(escape(node.id))\",\"parentID\":\"\(escape(parent))\",\"position\":\(node.position),\"kind\":\"\(node.kind.rawValue)\",\"label\":\"\(escape(label))\",\"targetID\":\"\(escape(target))\"}"
            }
            return Result(
                output: lines.joined(separator: "\n"),
                didCommit: false
            )
        }
        // TSV: id <tab> parentID <tab> position <tab> kind <tab> label <tab> targetID
        let lines = nodes.map { node in
            "\(node.id)\t\(node.parentID ?? "")\t\(node.position)\t\(node.kind.rawValue)\t\(node.label ?? "")\t\(node.targetID?.rawValue ?? "")"
        }
        return Result(
            output: lines.joined(separator: "\n"),
            didCommit: false
        )
    }

    /// Minimal JSON string escaping for manual JSONL output.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - create-folder

    private static func createFolder(parentID: String?, name: String, in store: WikiStore) throws -> Result {
        let node = try store.createBookmarkNode(
            parentID: parentID, position: -1, kind: .folder, label: name, targetID: nil
        )
        return Result(output: "Created folder \"\(name)\" (id: \(node.id)).", didCommit: true)
    }

    // MARK: - add-ref

    private static func addRef(
        parentID: String?, kind: BookmarkNodeKind, targetID: PageID, in store: WikiStore
    ) throws -> Result {
        let node = try store.createBookmarkNode(
            parentID: parentID, position: -1, kind: kind, label: nil, targetID: targetID
        )
        let kindLabel: String
        switch kind {
        case .pageRef: kindLabel = "page"
        case .sourceRef: kindLabel = "source"
        case .chatRef: kindLabel = "chat"
        case .folder: kindLabel = "folder"
        }
        return Result(
            output: "Added \(kindLabel) ref (\(targetID.rawValue)) to bookmarks (id: \(node.id)).",
            didCommit: true
        )
    }

    // MARK: - rename

    private static func rename(id: String, to newName: String, in store: WikiStore) throws -> Result {
        try store.updateBookmarkNode(id: id, label: newName)
        return Result(output: "Renamed bookmark node \(id) to \"\(newName)\".", didCommit: true)
    }

    // MARK: - delete

    private static func delete(id: String, in store: WikiStore) throws -> Result {
        try store.deleteBookmarkNode(id: id)
        return Result(output: "Deleted bookmark node \(id) (and descendants).", didCommit: true)
    }

    // MARK: - move

    private static func move(id: String, toParentID: String?, position: Int, in store: WikiStore) throws -> Result {
        try store.moveBookmarkNode(id: id, toParentID: toParentID, position: position)
        return Result(output: "Moved bookmark node \(id).", didCommit: true)
    }
}
