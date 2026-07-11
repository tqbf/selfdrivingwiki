import Foundation
import WikiFSCore

/// The `wikictl workspace …` subcommands (W1, PR #312). Managed workspace
/// lifecycle: create, status, abandon, merge. Testable against a temp DB.
public enum WorkspaceCommand {

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
        case create(name: String?)
        case status(id: String)
        case abandon(id: String)
        case merge(id: String)
        case refresh(id: String)
        case conflicts(id: String)
        case resolve(id: String, pageID: PageID, bodyFile: String)
        case retry(id: String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    public static func run(_ action: Action, in store: WikiStore) throws -> Result {
        switch action {
        case .create(let name):
            return try create(name: name, in: store)
        case .status(let id):
            return try status(id: id, in: store)
        case .abandon(let id):
            return try abandon(id: id, in: store)
        case .merge(let id):
            return try merge(id: id, in: store)
        case .refresh(let id):
            return try refresh(id: id, in: store)
        case .conflicts(let id):
            return try conflicts(id: id, in: store)
        case .resolve(let id, let pageID, let bodyFile):
            return try resolve(id: id, pageID: pageID, bodyFile: bodyFile, in: store)
        case .retry(let id):
            return try retry(id: id, in: store)
        }
    }

    // MARK: - create

    private static func create(name: String?, in store: WikiStore) throws -> Result {
        let id = try store.createWorkspace(name: name, activityID: nil)
        return Result(output: id, didCommit: true)
    }

    // MARK: - status

    private static func status(id: String, in store: WikiStore) throws -> Result {
        guard let ws = try store.workspaceSummary(id: id) else {
            throw Failure.message("workspace \(id) not found")
        }
        var lines = ["\(ws.id)\t\(ws.status.rawValue)\t\(ws.name ?? "")"]
        let refs = try store.workspaceRefs(workspaceID: id)
        if refs.isEmpty {
            lines.append("(no pages)")
        } else {
            for ref in refs {
                let base = ref.baseVersionID ?? "—"
                lines.append("  \(ref.ownerID.rawValue)\tbase=\(base.prefix(12))\thead=\(ref.versionID.prefix(12))")
            }
        }
        return Result(output: lines.joined(separator: "\n"), didCommit: false)
    }

    // MARK: - abandon

    private static func abandon(id: String, in store: WikiStore) throws -> Result {
        try store.abandonWorkspace(id: id)
        return Result(output: "abandoned \(id)", didCommit: true)
    }

    // MARK: - merge

    private static func merge(id: String, in store: WikiStore) throws -> Result {
        try store.workspaceMerge(workspaceID: id)
        let ws = try store.workspaceSummary(id: id)
        let status = ws?.status.rawValue ?? "unknown"
        return Result(output: "merge: \(id) → \(status)", didCommit: true)
    }

    // MARK: - refresh

    private static func refresh(id: String, in store: WikiStore) throws -> Result {
        try store.workspaceRefresh(workspaceID: id)
        let ws = try store.workspaceSummary(id: id)
        let status = ws?.status.rawValue ?? "unknown"
        return Result(output: "refresh: \(id) → \(status)", didCommit: true)
    }

    // MARK: - conflicts

    private static func conflicts(id: String, in store: WikiStore) throws -> Result {
        let conflicts = try store.workspaceConflicts(workspaceID: id)
        if conflicts.isEmpty {
            return Result(output: "(no conflicts)", didCommit: false)
        }
        let lines = conflicts.map { c in
            let page = c.pageID.rawValue
            let base = c.baseVersionID ?? "—" 
            let main = c.mainVersionID ?? "—"
            let ws = c.wsVersionID
            return "\(page)\tbase=\(base.prefix(12))\tmain=\(main.prefix(12))\tws=\(ws.prefix(12))"
        }
        return Result(output: lines.joined(separator: "\n"), didCommit: false)
    }

    // MARK: - resolve

    private static func resolve(
        id: String, pageID: PageID, bodyFile: String, in store: WikiStore
    ) throws -> Result {
        let body: String
        if bodyFile == "-" {
            body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else {
            body = try String(contentsOfFile: bodyFile, encoding: .utf8)
        }
        try store.workspaceResolveConflict(workspaceID: id, pageID: pageID, body: body)
        return Result(output: "resolved \(pageID.rawValue) in \(id)", didCommit: true)
    }

    // MARK: - retry

    private static func retry(id: String, in store: WikiStore) throws -> Result {
        try store.workspaceRetryMerge(workspaceID: id)
        let ws = try store.workspaceSummary(id: id)
        let status = ws?.status.rawValue ?? "unknown"
        return Result(output: "retry: \(id) → \(status)", didCommit: true)
    }
}
