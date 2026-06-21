import Foundation
import WikiFSCore

/// The `wikictl file …` subcommands, executed against an already-opened
/// `WikiStore`. Split from process concerns (arg parsing, stdin, the Darwin
/// post, opening the DB) so the whole command surface is unit-testable against
/// a temp DB.
///
/// Unlike `PageCommand` whose output is always a `String`, `FileCommand` can
/// emit raw bytes (`file cat` for binary/PDF sources). Its `Result` carries a
/// `Payload` enum: `.text(String)` (for `list`, `export`'s printed path) or
/// `.bytes(Data)` (for `cat`). `main` writes `.text` via `print` and `.bytes`
/// via `FileHandle.standardOutput.write`.
public enum FileCommand {

    /// What a command produced. Reads never commit; `didCommit` is always false.
    public struct Result: Equatable {
        public var payload: Payload
        public var didCommit: Bool

        public init(payload: Payload, didCommit: Bool) {
            self.payload = payload
            self.didCommit = didCommit
        }

        public enum Payload: Equatable {
            case text(String)
            case bytes(Data)
        }
    }

    /// How a file is selected for `cat` / `export`.
    public enum Selector: Equatable {
        case id(PageID)
        case name(String)
    }

    public enum Action: Equatable {
        case list(json: Bool)
        case cat(Selector)
        case export(Selector, out: String?)
    }

    public enum Failure: Error, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let text): text
            }
        }
    }

    /// Run one action against `store`. `cwd` is the directory for `export`'s
    /// default output path (injected for testability). All actions are pure
    /// reads — `didCommit` is always false.
    public static func run(_ action: Action, in store: WikiStore, cwd: String) throws -> Result {
        switch action {
        case .list(let json):
            return try list(in: store, json: json)
        case .cat(let selector):
            return try cat(selector, in: store)
        case .export(let selector, let out):
            return try export(selector, out: out, in: store, cwd: cwd)
        }
    }

    // MARK: - list

    private static func list(in store: WikiStore, json: Bool) throws -> Result {
        let summaries = try store.listSources()
        if json {
            // Sort by id (ULID = ingest order) to match indexes/files.jsonl.
            let sorted = summaries.sorted { $0.id.rawValue < $1.id.rawValue }
            let rows = sorted.map { summary in
                IndexGenerators.SourceIndexRow(
                    id: summary.id.rawValue,
                    filename: summary.filename,
                    ext: summary.ext,
                    mime: summary.mimeType,
                    byteSize: summary.byteSize,
                    createdAt: summary.createdAt,
                    updatedAt: summary.updatedAt,
                    version: summary.version
                )
            }
            let data = IndexGenerators.sourcesJSONL(sources: rows)
            return Result(
                payload: .text(String(decoding: data, as: UTF8.self)),
                didCommit: false
            )
        }
        // TSV: id <tab> name <tab> size <tab> mime, one file per line.
        let lines = summaries.map { summary in
            let mime = summary.mimeType ?? ""
            return "\(summary.id.rawValue)\t\(summary.filename)\t\(summary.byteSize)\t\(mime)"
        }
        return Result(
            payload: .text(lines.joined(separator: "\n")),
            didCommit: false
        )
    }

    // MARK: - cat

    private static func cat(_ selector: Selector, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        let data: Data
        do {
            data = try store.sourceContent(id: id)
        } catch {
            throw Failure.message("file not found: \(id.rawValue)")
        }
        return Result(payload: .bytes(data), didCommit: false)
    }

    // MARK: - export

    private static func export(
        _ selector: Selector,
        out: String?,
        in store: WikiStore,
        cwd: String
    ) throws -> Result {
        let id = try resolve(selector, in: store)
        let data: Data
        do {
            data = try store.sourceContent(id: id)
        } catch {
            throw Failure.message("file not found: \(id.rawValue)")
        }

        let path: String
        if let out {
            path = out
        } else {
            // Derive ext from the file's stored metadata to build the default name.
            let summaries = try store.listSources()
            let ext = summaries.first(where: { $0.id == id })?.ext ?? ""
            let leaf = ext.isEmpty
                ? "file-\(id.rawValue)"
                : "file-\(id.rawValue).\(ext)"
            path = "\(cwd)/\(leaf)"
        }

        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return Result(payload: .text(path), didCommit: false)
    }

    // MARK: - Selector resolution

    private static func resolve(_ selector: Selector, in store: WikiStore) throws -> PageID {
        switch selector {
        case .id(let id):
            return id
        case .name(let name):
            let summaries = try store.listSources()
            let matches = summaries.filter { $0.filename == name }
            switch matches.count {
            case 0:
                throw Failure.message("no file named \(name.debugDescription)")
            case 1:
                return matches[0].id
            default:
                let ids = matches.map { $0.id.rawValue }.sorted().joined(separator: ", ")
                throw Failure.message(
                    "multiple files named \(name.debugDescription) — resolve with --id: \(ids)"
                )
            }
        }
    }
}
