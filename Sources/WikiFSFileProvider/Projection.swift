import FileProvider
import Foundation
import WikiFSCore

/// The read-only SQLite-backed projection that replaces the spike's static
/// `Catalog`. Owns:
///   * the identity ↔ row mapping (virtual ids; paths are presentation only),
///   * the static `README.md` bytes,
///   * `node(for:)` / `children(of:)` / `contents(for:)`, each opening a
///     fresh, short-lived read store (INITIAL §10 — the app is the only writer;
///     WAL + `query_only` reads are safe concurrently).
///
/// The id embedded in a page identifier is ALWAYS the full ULID, never the
/// filename — filenames are derived for presentation (INITIAL §6).
///
/// **Multi-wiki (Phase 0).** A `Projection` is bound to ONE wiki via `wikiID`
/// (the ULID the File Provider domain identifier carries). `openReadStore()`
/// resolves that wiki's `<ulid>.sqlite`, so the SAME projection logic serves any
/// wiki — the only difference is which DB it opens. The extension constructs one
/// `Projection(wikiID:)` from `init(domain:)` and threads it through the
/// enumerator. `Identity`, the static README/version bytes, and the index byte
/// cache stay static (they don't depend on which wiki).
struct Projection {

    /// The wiki this projection serves: the ULID from the FP domain identifier.
    /// `openReadStore()` maps it to `<ulid>.sqlite` in the App Group container.
    let wikiID: String

    // MARK: - Identity

    /// Stable virtual identifiers. The page identifiers carry the full ULID.
    enum Identity {
        static let readme = NSFileProviderItemIdentifier("readme")
        static let pages = NSFileProviderItemIdentifier("pages")
        // Container ids come from the shared `WikiFSContainerID` constants so the
        // extension and the app's `signalChange()` can't drift (a mismatch would
        // leave the page list stale after an edit).
        static let pagesByID = NSFileProviderItemIdentifier(WikiFSContainerID.pagesByID)
        static let pagesByTitle = NSFileProviderItemIdentifier(WikiFSContainerID.pagesByTitle)

        // Generated agent-facing index files (Phase 4). `manifest.json` lives at
        // the root; the JSONL files live under the `indexes` folder.
        static let manifest = NSFileProviderItemIdentifier(WikiFSContainerID.manifest)
        static let indexes = NSFileProviderItemIdentifier(WikiFSContainerID.indexes)
        static let indexPagesJSONL = NSFileProviderItemIdentifier(WikiFSContainerID.indexPagesJSONL)
        static let indexLinksJSONL = NSFileProviderItemIdentifier(WikiFSContainerID.indexLinksJSONL)

        // Sources (Phase 5, renamed v10): a top-level `sources/` tree with `by-id`
        // and `by-name` views, plus `indexes/sources.jsonl`.
        static let sources = NSFileProviderItemIdentifier(WikiFSContainerID.sources)
        static let sourcesByID = NSFileProviderItemIdentifier(WikiFSContainerID.sourcesByID)
        static let sourcesByName = NSFileProviderItemIdentifier(WikiFSContainerID.sourcesByName)
        static let indexSourcesJSONL = NSFileProviderItemIdentifier(WikiFSContainerID.indexSourcesJSONL)

        // System prompt (v3): the same singleton document under two root-level
        // names (identical bytes) — `CLAUDE.md` and `AGENTS.md`.
        static let claudeMD = NSFileProviderItemIdentifier(WikiFSContainerID.claudeMD)
        static let agentsMD = NSFileProviderItemIdentifier(WikiFSContainerID.agentsMD)

        // Phase B: two more root-level read-only docs. `log.md` renders the
        // append-only `log` table as grep-able lines; `index.md` serves the
        // singleton `wiki_index` body verbatim.
        static let logMD = NSFileProviderItemIdentifier(WikiFSContainerID.logMD)
        static let indexMD = NSFileProviderItemIdentifier(WikiFSContainerID.indexMD)

        // Phase C: a root-level read-only orientation map of the wiki layout
        // (`WIKI-STRUCTURE.md` + legacy `TREE.md`), served exactly like
        // `log.md`/`index.md`.
        static let wikiStructureMD = NSFileProviderItemIdentifier(WikiFSContainerID.wikiStructureMD)
        static let treeMD = NSFileProviderItemIdentifier(WikiFSContainerID.treeMD)

        static let byIDPrefix = "page-by-id:"
        static let byTitlePrefix = "page-by-title:"
        // Shared with the app (which resolves a per-file user-visible URL to open
        // it in the default app), so the two sides build the identical identifier.
        static let sourceByIDPrefix = WikiFSContainerID.sourceByIDPrefix
        static let sourceByNamePrefix = "source-by-name:"

        static func pageByID(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(byIDPrefix + ulid)
        }

        static func pageByTitle(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(byTitlePrefix + ulid)
        }

        static func sourceByID(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(sourceByIDPrefix + ulid)
        }

        static func sourceByName(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(sourceByNamePrefix + ulid)
        }

        /// Extract the embedded ULID from a `page-by-id:` / `page-by-title:`
        /// identifier, or nil if it isn't a page identifier.
        static func pageULID(from id: NSFileProviderItemIdentifier) -> String? {
            let raw = id.rawValue
            if raw.hasPrefix(byIDPrefix) { return String(raw.dropFirst(byIDPrefix.count)) }
            if raw.hasPrefix(byTitlePrefix) { return String(raw.dropFirst(byTitlePrefix.count)) }
            return nil
        }

        /// Extract the embedded ULID from a `file-by-id:` / `file-by-name:`
        /// identifier, or nil if it isn't an ingested-file identifier. The full
        /// ULID is in the identifier — never the filename (INITIAL §6).
        static func fileULID(from id: NSFileProviderItemIdentifier) -> String? {
            let raw = id.rawValue
            if raw.hasPrefix(sourceByIDPrefix) { return String(raw.dropFirst(sourceByIDPrefix.count)) }
            if raw.hasPrefix(sourceByNamePrefix) { return String(raw.dropFirst(sourceByNamePrefix.count)) }
            return nil
        }
    }

    // MARK: - Static content

    /// The generated `README.md` (INITIAL §5). Static across the DB lifetime, so
    /// a constant version is correct.
    static let readmeBytes = Data("""
    # Self Driving Wiki

    This is a read-only filesystem projection of the Self Driving Wiki database.

    Useful paths:

    - `CLAUDE.md` / `AGENTS.md` (the agent system prompt — identical)
    - `index.md` (the curated catalog)
    - `log.md` (the append-only chronological log)
    - `WIKI-STRUCTURE.md` (the layout/orientation map)
    - `TREE.md` (legacy alias for `WIKI-STRUCTURE.md`)
    - `pages/by-id/`
    - `pages/by-title/`
    - `sources/by-id/`
    - `sources/by-name/`
    - `manifest.json`
    - `indexes/pages.jsonl`
    - `indexes/links.jsonl`
    - `indexes/sources.jsonl`

    """.utf8)

    /// A constant version stamp for static items (README + folders).
    static let staticVersion = Data("1".utf8)

    // MARK: - Generated index byte cache (token-keyed)

    /// Token-keyed cache for the three GENERATED files (manifest, the two
    /// JSONL). The cache is the single source of truth so a file's reported
    /// `documentSize` (from `node(for:)`) and its served bytes (from
    /// `contents(for:)`) are derived from the SAME `Data` for a given change
    /// token — a size/content mismatch would truncate `cat`.
    ///
    /// Keyed by `(identifier, token)`: when the token advances (any edit), the
    /// next lookup misses and regenerates. The generated bytes are deterministic
    /// for a fixed DB state EXCEPT the manifest's `generated_at`; we pin that to
    /// one timestamp per (token) entry so size==content holds within a token.
    /// NSLock-guarded token-keyed byte cache. A `final class` held in a `let`
    /// is the Sendable-safe way to own mutable shared state under Swift 6 strict
    /// concurrency (the mutation is serialized by the lock).
    private final class IndexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (token: String, data: Data)] = [:]

        func data(forKey key: String, token: String, generate: () -> Data?) -> Data? {
            lock.lock()
            if let cached = entries[key], cached.token == token {
                lock.unlock()
                return cached.data
            }
            lock.unlock()

            guard let data = generate() else { return nil }

            lock.lock()
            entries[key] = (token, data)
            lock.unlock()
            return data
        }
    }

    private static let indexCache = IndexCache()

    /// Return the generated bytes for one of the three index files at the
    /// current change token, regenerating (and caching) on a token miss.
    /// Returns nil only if the DB is unavailable. Keyed by `(wikiID, identifier)`
    /// so two wikis sharing the process-wide cache never collide.
    private func indexData(for id: NSFileProviderItemIdentifier) -> Data? {
        Self.indexCache.data(forKey: "\(wikiID)/\(id.rawValue)", token: changeToken()) {
            generateIndexData(for: id)
        }
    }

    /// Generate (no caching) the bytes for one index file from a fresh read
    /// store. The `generated_at` stamp in the manifest is "now" at generation
    /// time; once cached under a token it stays fixed until the token advances.
    private func generateIndexData(for id: NSFileProviderItemIdentifier) -> Data? {
        guard let store = openReadStore() else { return nil }
        switch id {
        case Identity.manifest:
            guard let pages = try? store.listAllPagesOrderedByID() else { return nil }
            // file_count must be resilient to a pre-migration `ingested_files`:
            // a `nil` read → 0, so the manifest still generates.
            let sourceCount = (try? store.listAllSourcesOrderedByID())?.count ?? 0
            return IndexGenerators.manifest(pages: pages, sourceCount: sourceCount, generatedAt: Date())
        case Identity.indexPagesJSONL:
            guard let pages = try? store.listAllPagesOrderedByID() else { return nil }
            return IndexGenerators.pagesJSONL(pages: pages)
        case Identity.indexLinksJSONL:
            guard let links = try? store.listAllLinks() else { return nil }
            return IndexGenerators.linksJSONL(links: links)
        case Identity.indexSourcesJSONL:
            // Resilient to the table not existing yet → empty index, never nil,
            // so enumeration of `indexes/` never errors pre-migration.
            let files = (try? store.listAllSourcesOrderedByID()) ?? []
            return IndexGenerators.sourcesJSONL(sources: files)
        default:
            return nil
        }
    }

    /// Build a file node for a generated index file, sizing it from the SAME
    /// cached bytes `contents(for:)` will serve, and versioning it by the
    /// current token so the daemon re-fetches after any edit.
    private func indexFileNode(for id: NSFileProviderItemIdentifier,
                               name: String,
                               parent: NSFileProviderItemIdentifier) -> ProjectedNode? {
        guard let data = indexData(for: id) else { return nil }
        let version = Data(changeToken().utf8)
        return .file(id: id, parent: parent, name: name, size: data.count,
                     version: version, metadataVersion: version,
                     created: nil, modified: nil)
    }

    // MARK: - Read store

    /// Open a fresh, short-lived read-only store at THIS wiki's `<ulid>.sqlite`
    /// in the App Group container. The wiki is selected by `wikiID` (the ULID the
    /// File Provider domain carries) — the multi-wiki crux: same projection code,
    /// different DB per domain. Returns nil if the container/DB is unavailable.
    private func openReadStore() -> SQLiteWikiStore? {
        guard let url = DatabaseLocation.extensionContainerURL(forWikiID: wikiID) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? SQLiteWikiStore(readOnlyURL: url)
    }

    // MARK: - System prompt (CLAUDE.md / AGENTS.md)

    /// The singleton system-prompt document, read live from SQLite. Falls back to
    /// the seeded default (`version 0`) when the row/table can't be read — e.g. a
    /// read connection opened against a not-yet-migrated DB — so `CLAUDE.md` and
    /// `AGENTS.md` ALWAYS exist at the root. Read live in both `node(for:)` (size)
    /// and `contents(for:)` (bytes), exactly like a page body; the row `version`
    /// drives the item version so an edit re-fetches.
    private func systemPromptDocument() -> SystemPrompt {
        guard let store = openReadStore(),
              let prompt = try? store.getSystemPrompt() else {
            return SystemPrompt(body: SystemPrompt.defaultBody,
                                updatedAt: Date(timeIntervalSince1970: 0), version: 0)
        }
        return prompt
    }

    /// Build the root-level file node for the system prompt under whichever name
    /// (`CLAUDE.md` / `AGENTS.md`) the identifier maps to. Both names serve the
    /// identical bytes and share the row's `version`.
    private func systemPromptNode(for id: NSFileProviderItemIdentifier,
                                  name: String) -> ProjectedNode {
        let prompt = systemPromptDocument()
        let body = Data(prompt.body.utf8)
        let version = Data(String(prompt.version).utf8)
        return .file(id: id, parent: .rootContainer, name: name, size: body.count,
                     version: version, metadataVersion: version,
                     created: nil, modified: prompt.updatedAt)
    }

    // MARK: - index.md (singleton catalog)

    /// The singleton `wiki_index` document, read live from SQLite. Falls back to
    /// the seeded default (`version 0`) when the row/table can't be read — e.g. a
    /// read connection opened against a not-yet-migrated DB — so `index.md` ALWAYS
    /// exists at the root. Mirrors `systemPromptDocument()`.
    private func wikiIndexDocument() -> WikiIndex {
        guard let store = openReadStore(),
              let index = try? store.getWikiIndex() else {
            return WikiIndex(body: WikiIndex.defaultBody,
                             updatedAt: Date(timeIntervalSince1970: 0), version: 0)
        }
        return index
    }

    /// Build the root-level `index.md` file node, sized + versioned from the
    /// singleton row exactly like the system-prompt node.
    private func wikiIndexNode(for id: NSFileProviderItemIdentifier) -> ProjectedNode {
        let index = wikiIndexDocument()
        let body = Data(index.body.utf8)
        let version = Data(String(index.version).utf8)
        return .file(id: id, parent: .rootContainer, name: "index.md", size: body.count,
                     version: version, metadataVersion: version,
                     created: nil, modified: index.updatedAt)
    }

    // MARK: - log.md (append-only log)

    /// The rendered `log.md` body — the whole `log` table as grep-able lines.
    /// Resilient to the table not existing yet (pre-v4 read connection) → empty,
    /// so the file always exists. Like the generated index files, its bytes derive
    /// from many rows (not a single versioned row), so its node is versioned by the
    /// change token rather than a row `version`.
    private func logBody() -> Data {
        guard let store = openReadStore(),
              let entries = try? store.listAllLogEntriesOrderedByID() else {
            return Data(LogRenderer.render([]).utf8)
        }
        return Data(LogRenderer.render(entries).utf8)
    }

    /// Build the root-level `log.md` file node, sized from the rendered body and
    /// versioned by the change token so any append re-fetches it (the append bumps
    /// the token's `logCount` fold).
    private func logNode(for id: NSFileProviderItemIdentifier) -> ProjectedNode {
        let body = logBody()
        let version = Data(changeToken().utf8)
        return .file(id: id, parent: .rootContainer, name: "log.md", size: body.count,
                     version: version, metadataVersion: version,
                     created: nil, modified: nil)
    }

    // MARK: - WIKI-STRUCTURE.md / TREE.md (layout/orientation map)

    /// The rendered layout-map body — a deterministic map of the wiki's FIXED
    /// layout (`WikiTreeRenderer`) plus two cheap live counts (pages, files).
    /// Resilient to the tables not existing yet (pre-migration read connection) →
    /// zero counts, so the file always exists. The layout text is static; only the
    /// counts move, and they move with the same page/file folds the change token
    /// already tracks.
    private func treeBody() -> Data {
        let store = openReadStore()
        let pageCount = (try? store?.listAllPagesOrderedByID())??.count ?? 0
        let sourceCount = (try? store?.listAllSourcesOrderedByID())??.count ?? 0
        return Data(WikiTreeRenderer.render(pageCount: pageCount, sourceCount: sourceCount).utf8)
    }

    /// Build a root-level layout-map file node. Versioned by the change token (like
    /// `log.md`): the layout text is static, but the two folded-in counts move with
    /// any page/file create, and those are exactly the folds the token tracks.
    private func treeNode(for id: NSFileProviderItemIdentifier, name: String) -> ProjectedNode {
        let body = treeBody()
        let version = Data(changeToken().utf8)
        return .file(id: id, parent: .rootContainer, name: name, size: body.count,
                     version: version, metadataVersion: version,
                     created: nil, modified: nil)
    }

    // MARK: - Change token (sync anchor)

    /// The whole-database change token used as the File Provider sync anchor.
    /// Advances on ANY page create/update/delete (count:sum — see
    /// `SQLiteWikiStore.changeToken()`). Opens a short-lived read store; returns
    /// a safe `"0:0"` default if the DB is unavailable so the enumerator can
    /// still answer (and a later real token simply differs → re-sync).
    func changeToken() -> String {
        guard let store = openReadStore(),
              let token = try? store.changeToken() else { return "0:0" }
        return token
    }

    // MARK: - Metadata resolution

    /// Resolve a single item's metadata by identifier.
    func node(for id: NSFileProviderItemIdentifier) -> ProjectedNode? {
        if id == .rootContainer {
            return .folder(id: .rootContainer, parent: .rootContainer, name: "Self Driving Wiki")
        }
        switch id {
        case Identity.readme:
            return .file(id: id, parent: .rootContainer, name: "README.md",
                         size: Self.readmeBytes.count, version: Self.staticVersion,
                         metadataVersion: Self.staticVersion,
                         created: nil, modified: nil)
        case Identity.claudeMD:
            return systemPromptNode(for: id, name: "CLAUDE.md")
        case Identity.agentsMD:
            return systemPromptNode(for: id, name: "AGENTS.md")
        case Identity.indexMD:
            return wikiIndexNode(for: id)
        case Identity.logMD:
            return logNode(for: id)
        case Identity.wikiStructureMD:
            return treeNode(for: id, name: "WIKI-STRUCTURE.md")
        case Identity.treeMD:
            return treeNode(for: id, name: "TREE.md")
        case Identity.pages:
            return .folder(id: id, parent: .rootContainer, name: "pages")
        case Identity.pagesByID:
            return .folder(id: id, parent: Identity.pages, name: "by-id")
        case Identity.pagesByTitle:
            return .folder(id: id, parent: Identity.pages, name: "by-title")
        case Identity.manifest:
            return indexFileNode(for: id, name: "manifest.json", parent: .rootContainer)
        case Identity.indexes:
            return .folder(id: id, parent: .rootContainer, name: "indexes")
        case Identity.indexPagesJSONL:
            return indexFileNode(for: id, name: "pages.jsonl", parent: Identity.indexes)
        case Identity.indexLinksJSONL:
            return indexFileNode(for: id, name: "links.jsonl", parent: Identity.indexes)
        case Identity.indexSourcesJSONL:
            return indexFileNode(for: id, name: "files.jsonl", parent: Identity.indexes)
        case Identity.sources:
            return .folder(id: id, parent: .rootContainer, name: "files")
        case Identity.sourcesByID:
            return .folder(id: id, parent: Identity.sources, name: "by-id")
        case Identity.sourcesByName:
            return .folder(id: id, parent: Identity.sources, name: "by-name")
        default:
            break
        }
        // Ingested-file leaf (file-by-id: / file-by-name:). Resolve the embedded
        // ULID and look up the summary; resilient to a missing table (the read
        // throws → nil → the node simply isn't found, never an enumeration error).
        if let ulid = Identity.fileULID(from: id) {
            guard let store = openReadStore(),
                  let file = try? store.getSource(id: PageID(rawValue: ulid)) else {
                return nil
            }
            return Self.sourceNode(for: id, file: file)
        }
        guard let ulid = Identity.pageULID(from: id),
              let store = openReadStore(),
              let page = try? store.getPage(id: PageID(rawValue: ulid)) else {
            return nil
        }
        return Self.pageFileNode(for: id, page: page)
    }

    /// Build a file node for an ingested-file row, under whichever view `id`
    /// belongs to. Size is the stored `byteSize` (NEVER nil → no truncated
    /// `cat`); contentVersion is the row `version`; metadataVersion folds in the
    /// filename + updated_at so a re-ingest under the same id would re-fetch.
    static func sourceNode(for id: NSFileProviderItemIdentifier,
                                 file: SourceSummary) -> ProjectedNode {
        let raw = id.rawValue
        let isByName = raw.hasPrefix(Identity.sourceByNamePrefix)
        let name = isByName
            ? FilenameEscaping.byNameSourceFilename(
                filename: file.filename, ext: file.ext, sourceID: file.id.rawValue)
            : FilenameEscaping.byIDSourceFilename(sourceID: file.id.rawValue, ext: file.ext)
        let parent = isByName ? Identity.sourcesByName : Identity.sourcesByID
        return .file(
            id: id, parent: parent, name: name, size: file.byteSize,
            version: Data(String(file.version).utf8),
            metadataVersion: Data(
                "\(file.filename)|\(file.updatedAt.timeIntervalSince1970)|\(file.version)".utf8),
            created: file.createdAt, modified: file.updatedAt,
            ingestedExt: file.ext
        )
    }

    /// Build a file node for a page row, under whichever view `id` belongs to.
    static func pageFileNode(for id: NSFileProviderItemIdentifier,
                             page: WikiPage) -> ProjectedNode {
        let raw = id.rawValue
        let isByTitle = raw.hasPrefix(Identity.byTitlePrefix)
        let name = isByTitle
            ? FilenameEscaping.byTitleFilename(title: page.title, pageID: page.id.rawValue)
            : FilenameEscaping.byIDFilename(pageID: page.id.rawValue)
        let parent = isByTitle ? Identity.pagesByTitle : Identity.pagesByID
        let body = Data(page.bodyMarkdown.utf8)
        return .file(
            id: id, parent: parent, name: name, size: body.count,
            version: Data(String(page.version).utf8),
            metadataVersion: Data(
                "\(page.title)|\(page.updatedAt.timeIntervalSince1970)|\(page.version)".utf8),
            created: page.createdAt, modified: page.updatedAt
        )
    }

    // MARK: - Enumeration

    /// Children of a container. Root → README + pages; pages → by-id + by-title;
    /// by-id/by-title → one file per page row (ordered by ULID == creation
    /// order). Other containers (files) → empty.
    func children(of container: NSFileProviderItemIdentifier) -> [ProjectedNode] {
        switch container {
        case .rootContainer:
            return [
                node(for: Identity.readme),
                node(for: Identity.claudeMD),
                node(for: Identity.agentsMD),
                node(for: Identity.indexMD),
                node(for: Identity.logMD),
                node(for: Identity.wikiStructureMD),
                node(for: Identity.treeMD),
                node(for: Identity.manifest),
                node(for: Identity.pages),
                node(for: Identity.sources),
                node(for: Identity.indexes),
            ].compactMap { $0 }
        case Identity.pages:
            return [
                node(for: Identity.pagesByID),
                node(for: Identity.pagesByTitle),
            ].compactMap { $0 }
        case Identity.sources:
            return [
                node(for: Identity.sourcesByID),
                node(for: Identity.sourcesByName),
            ].compactMap { $0 }
        case Identity.indexes:
            return [
                node(for: Identity.indexPagesJSONL),
                node(for: Identity.indexLinksJSONL),
                node(for: Identity.indexSourcesJSONL),
            ].compactMap { $0 }
        case Identity.pagesByID:
            return pageNodes(byTitle: false)
        case Identity.pagesByTitle:
            return pageNodes(byTitle: true)
        case Identity.sourcesByID:
            return sourceNodes(byName: false)
        case Identity.sourcesByName:
            return sourceNodes(byName: true)
        case .workingSet:
            // The working set is the set of items the daemon actively tracks for
            // change. Re-emit ALL page nodes (both views) and ALL ingested-file
            // nodes (both views) PLUS the generated index nodes so a working-set
            // `enumerateChanges` after a signal carries the new itemVersions and
            // the daemon invalidates its materialized copies (the index bytes
            // derive from page + file content, so a mutation must invalidate them).
            return pageNodes(byTitle: false) + pageNodes(byTitle: true)
                + sourceNodes(byName: false) + sourceNodes(byName: true)
                + [Identity.manifest, Identity.indexPagesJSONL,
                   Identity.indexLinksJSONL, Identity.indexSourcesJSONL,
                   Identity.claudeMD, Identity.agentsMD,
                   Identity.indexMD, Identity.logMD,
                   Identity.wikiStructureMD, Identity.treeMD]
                    .compactMap { node(for: $0) }
        default:
            return []
        }
    }

    /// All page rows projected as file nodes under the given view, ordered by id
    /// (ULID == creation order).
    private func pageNodes(byTitle: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let pages = try? store.listAllPagesOrderedByID() else { return [] }
        return pages.map { page in
            let id = byTitle ? Identity.pageByTitle(page.id.rawValue)
                             : Identity.pageByID(page.id.rawValue)
            return Self.pageFileNode(for: id, page: page)
        }
    }

    /// All ingested-file rows projected as file nodes under the given view,
    /// ordered by id (ULID == ingest order). Resilient to the table not existing
    /// yet (pre-migration) → empty, so enumeration never errors.
    private func sourceNodes(byName: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let files = try? store.listAllSourcesOrderedByID() else { return [] }
        return files.map { row in
            let id = byName ? Identity.sourceByName(row.id) : Identity.sourceByID(row.id)
            let summary = SourceSummary(
                id: PageID(rawValue: row.id), filename: row.filename, ext: row.ext,
                mimeType: row.mime, byteSize: row.byteSize,
                createdAt: row.createdAt, updatedAt: row.updatedAt, version: row.version)
            return Self.sourceNode(for: id, file: summary)
        }
    }

    // MARK: - Content

    /// Materialize the bytes for a file identifier. README is static; page files
    /// read the live body from SQLite. Folders return nil.
    func contents(for id: NSFileProviderItemIdentifier) -> Data? {
        if id == Identity.readme { return Self.readmeBytes }
        // System prompt: both names serve the same live body (read like a page).
        if id == Identity.claudeMD || id == Identity.agentsMD {
            return Data(systemPromptDocument().body.utf8)
        }
        // index.md: the singleton catalog body, served verbatim (like the prompt).
        if id == Identity.indexMD {
            return Data(wikiIndexDocument().body.utf8)
        }
        // log.md: the whole log table rendered as grep-able lines.
        if id == Identity.logMD {
            return logBody()
        }
        // WIKI-STRUCTURE.md / TREE.md: the layout/orientation map + live counts.
        if id == Identity.wikiStructureMD || id == Identity.treeMD {
            return treeBody()
        }
        // Generated index sources: serve the SAME token-cached bytes whose length
        // `node(for:)` reported as `documentSize` (else `cat` truncates).
        if id == Identity.manifest || id == Identity.indexPagesJSONL
            || id == Identity.indexLinksJSONL || id == Identity.indexSourcesJSONL {
            return indexData(for: id)
        }
        // Ingested sources: serve the verbatim bytes from SQLite (raw, no
        // conversion). Resilient to a missing row/table → nil (noSuchItem).
        if let fileULID = Identity.fileULID(from: id) {
            guard let store = openReadStore(),
                  let data = try? store.sourceContent(id: PageID(rawValue: fileULID)) else {
                return nil
            }
            return data
        }
        guard let ulid = Identity.pageULID(from: id),
              let store = openReadStore(),
              let page = try? store.getPage(id: PageID(rawValue: ulid)) else {
            return nil
        }
        return Data(page.bodyMarkdown.utf8)
    }
}

/// A resolved projection node — a plain value the `WikiFSItem`
/// `NSFileProviderItem` wraps. Carries everything `getattr`/enumeration need.
struct ProjectedNode {
    let id: NSFileProviderItemIdentifier
    let parent: NSFileProviderItemIdentifier
    let name: String
    let isFolder: Bool
    let size: Int
    let contentVersion: Data
    let metadataVersion: Data
    let created: Date?
    let modified: Date?
    /// Set ONLY for ingested-file leaves: the original lowercased extension (no
    /// dot, `""` if none). `WikiFSItem.contentType` uses it to derive the file's
    /// UTType for ingested files WITHOUT touching the page/index branches. `nil`
    /// for every other node kind (pages, folders, generated indexes).
    let ingestedExt: String?

    static func folder(id: NSFileProviderItemIdentifier,
                       parent: NSFileProviderItemIdentifier,
                       name: String) -> ProjectedNode {
        ProjectedNode(id: id, parent: parent, name: name, isFolder: true, size: 0,
                      contentVersion: Projection.staticVersion,
                      metadataVersion: Projection.staticVersion,
                      created: nil, modified: nil, ingestedExt: nil)
    }

    static func file(id: NSFileProviderItemIdentifier,
                     parent: NSFileProviderItemIdentifier,
                     name: String, size: Int,
                     version: Data, metadataVersion: Data,
                     created: Date?, modified: Date?,
                     ingestedExt: String? = nil) -> ProjectedNode {
        ProjectedNode(id: id, parent: parent, name: name, isFolder: false, size: size,
                      contentVersion: version, metadataVersion: metadataVersion,
                      created: created, modified: modified, ingestedExt: ingestedExt)
    }
}
