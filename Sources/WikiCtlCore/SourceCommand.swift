import Foundation
import WikiFSCore

/// The `wikictl source …` subcommands, executed against an already-opened
/// `WikiStore`. Split from process concerns (arg parsing, stdin, the Darwin
/// post, opening the DB) so the whole command surface is unit-testable against
/// a temp DB.
///
/// Unlike `PageCommand` whose output is always a `String`, `SourceCommand` can
/// emit raw bytes (`source cat` for binary/PDF sources). Its `Result` carries a
/// `Payload` enum: `.text(String)` (for `list`, `export`'s printed path) or
/// `.bytes(Data)` (for `cat`). `main` writes `.text` via `print` and `.bytes`
/// via `FileHandle.standardOutput.write`.
public enum SourceCommand {

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
    public enum Selector: Equatable, Sendable {
        case id(PageID)
        case name(String)
    }

    public enum Action: Equatable {
        case list(json: Bool)
        case cat(Selector, markdown: Bool)
        case export(Selector, out: String?, markdown: Bool)
        case editMarkdown(Selector, content: BodySource)
        case rename(Selector, to: String)
        case search(query: String, limit: Int)
        case setActive(Selector, versionID: PageID)
        case info(Selector)
        case refresh(Selector)
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
    ///
    /// `bm25Leg` is the pre-resolved Tantivy BM25 leg for the `.search` action
    /// (#637). Post-#634 this is the SOLE BM25 leg (FTS5 was dropped); `nil`
    /// (the default) means no BM25 results — only the cosine semantic leg runs.
    /// Caller-resolved via `CLITantivyLegResolver.resolveSourceLeg(...)`
    /// in `wikictl`'s `execute()`.
    public static func run(
        _ action: Action,
        in store: WikiStore,
        cwd: String,
        bm25Leg: [SourceSummary]? = nil
    ) throws -> Result {
        switch action {
        case .list(let json):
            return try list(in: store, json: json)
        case .cat(let selector, let markdown):
            return try cat(selector, markdown: markdown, in: store)
        case .export(let selector, let out, let markdown):
            return try export(selector, out: out, markdown: markdown, in: store, cwd: cwd)
        case .editMarkdown(let selector, let contentSource):
            let content = try resolveBodySource(contentSource)
            return try editMarkdown(selector, content: content, in: store)
        case .rename(let selector, let to):
            return try rename(selector, to: to, in: store)
        case .search(let query, let limit):
            return try search(query: query, limit: limit, bm25Leg: bm25Leg, in: store)
        case .setActive(let selector, let versionID):
            return try setActive(selector, versionID: versionID, in: store)
        case .info(let selector):
            return try info(selector, in: store)
        case .refresh:
            // Refresh is async-only — routed via `runRefresh` from `main.swift`.
            // This case is unreachable through the sync `run` path.
            throw Failure.message("source refresh requires async execution")
        }
    }

    // MARK: - list

    private static func list(in store: WikiStore, json: Bool) throws -> Result {
        let summaries = try store.listSources()
        if json {
            // Sort by id (ULID = ingest order) to match indexes/sources.jsonl.
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
                    version: summary.version,
                    displayName: summary.displayName
                    // hasMarkdown defaults to false — the authoritative
                    // sources.jsonl (on the mount) carries that field; the
                    // WikiStore protocol's listSources() doesn't expose it.
                )
            }
            let data = IndexGenerators.sourcesJSONL(sources: rows)
            return Result(
                payload: .text(String(decoding: data, as: UTF8.self)),
                didCommit: false
            )
        }
        // TSV: id <tab> name <tab> size <tab> mime, one file per line.
        // `name` is the display name when set, falling back to filename —
        // matching sourcesJSONL and how sources are labeled app-wide, so the
        // agent sees the same name it should use in [[source:Name]] citations.
        let lines = summaries.map { summary in
            let mime = summary.mimeType ?? ""
            let name = summary.effectiveName
            return "\(summary.id.rawValue)\t\(name)\t\(summary.byteSize)\t\(mime)"
        }
        return Result(
            payload: .text(lines.joined(separator: "\n")),
            didCommit: false
        )
    }

    // MARK: - cat

    private static func cat(
        _ selector: Selector, markdown: Bool, in store: WikiStore
    ) throws -> Result {
        let id = try resolve(selector, in: store)
        if markdown, let head = try store.processedMarkdownHead(sourceID: id) {
            // --markdown: print the extracted markdown HEAD instead of raw bytes.
            // Falls through to the raw-bytes path below when no markdown chain exists. (#553)
            return Result(payload: .text(head.content), didCommit: false)
        }
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
        markdown: Bool,
        in store: WikiStore,
        cwd: String
    ) throws -> Result {
        let id = try resolve(selector, in: store)

        // --markdown: export the extracted markdown HEAD as a .md sibling
        // instead of the raw blob. Falls back to raw bytes when no markdown
        // chain exists. (#553)
        if markdown, let head = try store.processedMarkdownHead(sourceID: id) {
            let path: String
            if let out {
                path = out
            } else {
                // Default to .md so the exported file is immediately usable.
                let summaries = try store.listSources()
                let baseName = summaries.first(where: { $0.id == id })?.ext ?? ""
                let leaf = baseName.isEmpty
                    ? "file-\(id.rawValue).md"
                    : "file-\(id.rawValue).\(baseName).md"
                path = "\(cwd)/\(leaf)"
            }
            try Data(head.content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return Result(payload: .text(path), didCommit: false)
        }

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
            // Match by display name first (display_name ?? filename), then
            // fall back to filename — mirrors `WikiStore.resolveSourceByName` and
            // how `source list` labels sources, so the agent can use the name it
            // just saw. (#554)
            let byDisplay = summaries.filter { $0.effectiveName == name }
            if byDisplay.count == 1 { return byDisplay[0].id }
            let byFilename = summaries.filter { $0.filename == name }
            if byFilename.count == 1 { return byFilename[0].id }
            let candidates = byDisplay.isEmpty ? byFilename : byDisplay
            switch candidates.count {
            case 0:
                throw Failure.message("no source named \(name.debugDescription)")
            default:
                let ids = candidates.map { $0.id.rawValue }.sorted().joined(separator: ", ")
                throw Failure.message(
                    "multiple sources named \(name.debugDescription) — resolve with --id: \(ids)"
                )
            }
        }
    }

    // MARK: - edit-markdown

    /// Replace the processed-markdown HEAD for a source. Errors when no markdown
    /// chain exists yet (extract first). Commits — the caller posts the Darwin
    /// notification on `didCommit`.
    private static func editMarkdown(_ selector: Selector, content: String, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        guard try store.hasProcessedMarkdown(sourceID: id) else {
            throw Failure.message("no processed markdown for this source")
        }
        try store.appendProcessedMarkdown(sourceID: id, content: content, origin: .user, note: nil, technique: nil)
        return Result(payload: .text(""), didCommit: true)
    }

    // MARK: - rename

    /// Rename a source's display name and rewrite `[[source:<old>…]]` links in
    /// every page that references it. Commits — the caller posts the Darwin
    /// notification on `didCommit`.
    private static func rename(_ selector: Selector, to newName: String, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        try store.renameSource(id: id, to: newName)
        return Result(payload: .text("Renamed source to \"\(newName)\"."), didCommit: true)
    }

    // MARK: - search

    /// Semantic source search (cosine ranking, LIKE fallback). Prints one
    /// `id<TAB>name` line per result, most relevant first — mirroring
    /// `PageCommand.search`. `name` is the display name, falling back to the
    /// filename (mirrors how sources are surfaced elsewhere). Read-only.
    private static func search(
        query: String, limit: Int, bm25Leg: [SourceSummary]?, in store: WikiStore
    ) throws -> Result {
        let results = try store.searchSimilarSources(query: query, limit: limit, bm25Leg: bm25Leg)
        let output: String = results.map { summary in
            // `effectiveName` falls back to filename on nil OR empty display_name,
            // matching how sources are labeled app-wide (sidebar/file-provider).
            let name = summary.effectiveName.replacingOccurrences(of: "\t", with: " ")
            return "\(summary.id.rawValue)\t\(name)"
        }.joined(separator: "\n")
        return Result(payload: .text(output), didCommit: false)
    }

    // MARK: - set-active

    /// Nominate an existing processed-markdown version as the active HEAD for a
    /// source (UPSERT the `source-derived` ref). Errors when the source has no
    /// markdown chain or the version doesn't belong to it. Commits — the caller
    /// posts the Darwin notification on `didCommit`.
    private static func setActive(
        _ selector: Selector, versionID: PageID, in store: WikiStore
    ) throws -> Result {
        let id = try resolve(selector, in: store)
        guard try store.hasProcessedMarkdown(sourceID: id) else {
            throw Failure.message("no processed markdown for this source")
        }
        try store.setActiveMarkdown(sourceID: id, to: versionID)
        return Result(
            payload: .text("Set active markdown to \(versionID.rawValue)."),
            didCommit: true)
    }

    // MARK: - info

    /// Print identity (filename, display name, mime, size) and origin provenance
    /// (provider agent, plan/URL, external identity, fetched-at) for a source.
    /// Mirrors `set-active`'s selector parsing. Read-only.
    private static func info(_ selector: Selector, in store: WikiStore) throws -> Result {
        let id = try resolve(selector, in: store)
        let summaries = try store.listSources()
        guard let summary = summaries.first(where: { $0.id == id }) else {
            throw Failure.message("source not found: \(id.rawValue)")
        }
        var lines: [String] = []
        lines.append("id\t\(summary.id.rawValue)")
        lines.append("filename\t\(summary.filename)")
        let display = summary.effectiveName
        lines.append("display\t\(display.isEmpty ? summary.filename : display)")
        lines.append("mime\t\(summary.mimeType ?? "")")
        lines.append("size\t\(summary.byteSize)")
        if let origin = try store.sourceOrigin(sourceID: id) {
            lines.append("provider\t\(origin.agentName)")
            lines.append("activity\t\(origin.activityKind)")
            if let plan = origin.plan { lines.append("plan\t\(plan)") }
            if let extID = origin.externalIdentity { lines.append("external_identity\t\(extID)") }
            if let extRef = origin.externalRef, extRef != origin.externalIdentity {
                lines.append("external_ref\t\(extRef)")
            }
            let date = ISO8601DateFormatter().string(from: origin.fetchedAt)
            lines.append("fetched_at\t\(date)")
        }
        return Result(payload: .text(lines.joined(separator: "\n")), didCommit: false)
    }

    // MARK: - refresh

    /// Re-fetch a source via its provider, appending a new version instead of
    /// overwriting. Unlike the other SourceCommand actions (all sync), this
    /// needs async network I/O, so it has its own async entry point. `main`
    /// bridges it to the sync `execute` context via a semaphore.
    ///
    /// wikictl is a CLI process (no `@MainActor`), so the store write happens
    /// directly after the off-main materialize — the Phase-0 `@MainActor`
    /// invariant applies to the APP process, not wikictl. The service is
    /// constructed with `podcastFetcher: nil` (no bundled signing helper in the
    /// CLI context), so podcast refresh throws `.signatureUnavailable` and only
    /// website sources are refreshable from the CLI. Commits — the caller posts
    /// the Darwin notification on `didCommit`.
    public static func runRefresh(
        _ selector: Selector,
        in store: WikiStore,
        fetcher: any URLFetchService.URLResourceFetcher
    ) async throws -> Result {
        let id = try resolve(selector, in: store)
        guard let origin = try store.sourceOrigin(sourceID: id) else {
            throw Failure.message("source has no origin provenance: \(id.rawValue)")
        }
        #if PODCAST_TRANSCRIPTS
        let service = SourceRefreshService(fetcher: fetcher, podcastFetcher: nil)
        #else
        let service = SourceRefreshService(fetcher: fetcher)
        #endif
        let material = try await service.materialize(origin: origin)
        switch material {
        case .contentVersion(let data, let prov):
            _ = try store.appendContentVersion(
                sourceID: id, data: data, mimeType: nil, provenance: prov)
        case .derivedMarkdown(let content):
            try store.appendProcessedMarkdown(
                sourceID: id, content: content, origin: .transcript, note: nil, technique: nil)
        }
        return Result(
            payload: .text("Refreshed \(origin.displayLabel) source."),
            didCommit: true)
    }
}
