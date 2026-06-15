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
enum Projection {

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

        // Ingested files (Phase 5): a new top-level `files/` tree with `by-id` and
        // `by-name` views, plus `indexes/files.jsonl`.
        static let files = NSFileProviderItemIdentifier(WikiFSContainerID.files)
        static let filesByID = NSFileProviderItemIdentifier(WikiFSContainerID.filesByID)
        static let filesByName = NSFileProviderItemIdentifier(WikiFSContainerID.filesByName)
        static let indexFilesJSONL = NSFileProviderItemIdentifier(WikiFSContainerID.indexFilesJSONL)

        static let byIDPrefix = "page-by-id:"
        static let byTitlePrefix = "page-by-title:"
        // Shared with the app (which resolves a per-file user-visible URL to open
        // it in the default app), so the two sides build the identical identifier.
        static let fileByIDPrefix = WikiFSContainerID.fileByIDPrefix
        static let fileByNamePrefix = "file-by-name:"

        static func pageByID(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(byIDPrefix + ulid)
        }

        static func pageByTitle(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(byTitlePrefix + ulid)
        }

        static func fileByID(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(fileByIDPrefix + ulid)
        }

        static func fileByName(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(fileByNamePrefix + ulid)
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
            if raw.hasPrefix(fileByIDPrefix) { return String(raw.dropFirst(fileByIDPrefix.count)) }
            if raw.hasPrefix(fileByNamePrefix) { return String(raw.dropFirst(fileByNamePrefix.count)) }
            return nil
        }
    }

    // MARK: - Static content

    /// The generated `README.md` (INITIAL §5). Static across the DB lifetime, so
    /// a constant version is correct.
    static let readmeBytes = Data("""
    # WikiFS

    This is a read-only filesystem projection of the WikiFS database.

    Useful paths:

    - `pages/by-id/`
    - `pages/by-title/`
    - `files/by-id/`
    - `files/by-name/`
    - `manifest.json`
    - `indexes/pages.jsonl`
    - `indexes/links.jsonl`
    - `indexes/files.jsonl`

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
    /// Returns nil only if the DB is unavailable.
    private static func indexData(for id: NSFileProviderItemIdentifier) -> Data? {
        indexCache.data(forKey: id.rawValue, token: changeToken()) {
            generateIndexData(for: id)
        }
    }

    /// Generate (no caching) the bytes for one index file from a fresh read
    /// store. The `generated_at` stamp in the manifest is "now" at generation
    /// time; once cached under a token it stays fixed until the token advances.
    private static func generateIndexData(for id: NSFileProviderItemIdentifier) -> Data? {
        guard let store = openReadStore() else { return nil }
        switch id {
        case Identity.manifest:
            guard let pages = try? store.listAllPagesOrderedByID() else { return nil }
            // file_count must be resilient to a pre-migration `ingested_files`:
            // a `nil` read → 0, so the manifest still generates.
            let fileCount = (try? store.listAllIngestedFilesOrderedByID())?.count ?? 0
            return IndexGenerators.manifest(pages: pages, fileCount: fileCount, generatedAt: Date())
        case Identity.indexPagesJSONL:
            guard let pages = try? store.listAllPagesOrderedByID() else { return nil }
            return IndexGenerators.pagesJSONL(pages: pages)
        case Identity.indexLinksJSONL:
            guard let links = try? store.listAllLinks() else { return nil }
            return IndexGenerators.linksJSONL(links: links)
        case Identity.indexFilesJSONL:
            // Resilient to the table not existing yet → empty index, never nil,
            // so enumeration of `indexes/` never errors pre-migration.
            let files = (try? store.listAllIngestedFilesOrderedByID()) ?? []
            return IndexGenerators.filesJSONL(files: files)
        default:
            return nil
        }
    }

    /// Build a file node for a generated index file, sizing it from the SAME
    /// cached bytes `contents(for:)` will serve, and versioning it by the
    /// current token so the daemon re-fetches after any edit.
    private static func indexFileNode(for id: NSFileProviderItemIdentifier,
                                      name: String,
                                      parent: NSFileProviderItemIdentifier) -> ProjectedNode? {
        guard let data = indexData(for: id) else { return nil }
        let version = Data(changeToken().utf8)
        return .file(id: id, parent: parent, name: name, size: data.count,
                     version: version, metadataVersion: version,
                     created: nil, modified: nil)
    }

    // MARK: - Read store

    /// Open a fresh, short-lived read-only store at the App Group container.
    /// Returns nil if the container/DB is unavailable.
    private static func openReadStore() -> SQLiteWikiStore? {
        guard let url = DatabaseLocation.extensionContainerURL() else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? SQLiteWikiStore(readOnlyURL: url)
    }

    // MARK: - Change token (sync anchor)

    /// The whole-database change token used as the File Provider sync anchor.
    /// Advances on ANY page create/update/delete (count:sum — see
    /// `SQLiteWikiStore.changeToken()`). Opens a short-lived read store; returns
    /// a safe `"0:0"` default if the DB is unavailable so the enumerator can
    /// still answer (and a later real token simply differs → re-sync).
    static func changeToken() -> String {
        guard let store = openReadStore(),
              let token = try? store.changeToken() else { return "0:0" }
        return token
    }

    // MARK: - Metadata resolution

    /// Resolve a single item's metadata by identifier.
    static func node(for id: NSFileProviderItemIdentifier) -> ProjectedNode? {
        if id == .rootContainer {
            return .folder(id: .rootContainer, parent: .rootContainer, name: "WikiFS")
        }
        switch id {
        case Identity.readme:
            return .file(id: id, parent: .rootContainer, name: "README.md",
                         size: readmeBytes.count, version: staticVersion,
                         metadataVersion: staticVersion,
                         created: nil, modified: nil)
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
        case Identity.indexFilesJSONL:
            return indexFileNode(for: id, name: "files.jsonl", parent: Identity.indexes)
        case Identity.files:
            return .folder(id: id, parent: .rootContainer, name: "files")
        case Identity.filesByID:
            return .folder(id: id, parent: Identity.files, name: "by-id")
        case Identity.filesByName:
            return .folder(id: id, parent: Identity.files, name: "by-name")
        default:
            break
        }
        // Ingested-file leaf (file-by-id: / file-by-name:). Resolve the embedded
        // ULID and look up the summary; resilient to a missing table (the read
        // throws → nil → the node simply isn't found, never an enumeration error).
        if let ulid = Identity.fileULID(from: id) {
            guard let store = openReadStore(),
                  let file = try? store.getIngestedFile(id: PageID(rawValue: ulid)) else {
                return nil
            }
            return ingestedFileNode(for: id, file: file)
        }
        guard let ulid = Identity.pageULID(from: id),
              let store = openReadStore(),
              let page = try? store.getPage(id: PageID(rawValue: ulid)) else {
            return nil
        }
        return pageFileNode(for: id, page: page)
    }

    /// Build a file node for an ingested-file row, under whichever view `id`
    /// belongs to. Size is the stored `byteSize` (NEVER nil → no truncated
    /// `cat`); contentVersion is the row `version`; metadataVersion folds in the
    /// filename + updated_at so a re-ingest under the same id would re-fetch.
    private static func ingestedFileNode(for id: NSFileProviderItemIdentifier,
                                         file: IngestedFileSummary) -> ProjectedNode {
        let raw = id.rawValue
        let isByName = raw.hasPrefix(Identity.fileByNamePrefix)
        let name = isByName
            ? FilenameEscaping.byNameIngestedFilename(
                filename: file.filename, ext: file.ext, fileID: file.id.rawValue)
            : FilenameEscaping.byIDIngestedFilename(fileID: file.id.rawValue, ext: file.ext)
        let parent = isByName ? Identity.filesByName : Identity.filesByID
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
    private static func pageFileNode(for id: NSFileProviderItemIdentifier,
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
    static func children(of container: NSFileProviderItemIdentifier) -> [ProjectedNode] {
        switch container {
        case .rootContainer:
            return [
                node(for: Identity.readme),
                node(for: Identity.manifest),
                node(for: Identity.pages),
                node(for: Identity.files),
                node(for: Identity.indexes),
            ].compactMap { $0 }
        case Identity.pages:
            return [
                node(for: Identity.pagesByID),
                node(for: Identity.pagesByTitle),
            ].compactMap { $0 }
        case Identity.files:
            return [
                node(for: Identity.filesByID),
                node(for: Identity.filesByName),
            ].compactMap { $0 }
        case Identity.indexes:
            return [
                node(for: Identity.indexPagesJSONL),
                node(for: Identity.indexLinksJSONL),
                node(for: Identity.indexFilesJSONL),
            ].compactMap { $0 }
        case Identity.pagesByID:
            return pageNodes(byTitle: false)
        case Identity.pagesByTitle:
            return pageNodes(byTitle: true)
        case Identity.filesByID:
            return ingestedFileNodes(byName: false)
        case Identity.filesByName:
            return ingestedFileNodes(byName: true)
        case .workingSet:
            // The working set is the set of items the daemon actively tracks for
            // change. Re-emit ALL page nodes (both views) and ALL ingested-file
            // nodes (both views) PLUS the generated index nodes so a working-set
            // `enumerateChanges` after a signal carries the new itemVersions and
            // the daemon invalidates its materialized copies (the index bytes
            // derive from page + file content, so a mutation must invalidate them).
            return pageNodes(byTitle: false) + pageNodes(byTitle: true)
                + ingestedFileNodes(byName: false) + ingestedFileNodes(byName: true)
                + [Identity.manifest, Identity.indexPagesJSONL,
                   Identity.indexLinksJSONL, Identity.indexFilesJSONL]
                    .compactMap { node(for: $0) }
        default:
            return []
        }
    }

    /// All page rows projected as file nodes under the given view, ordered by id
    /// (ULID == creation order).
    private static func pageNodes(byTitle: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let pages = try? store.listAllPagesOrderedByID() else { return [] }
        return pages.map { page in
            let id = byTitle ? Identity.pageByTitle(page.id.rawValue)
                             : Identity.pageByID(page.id.rawValue)
            return pageFileNode(for: id, page: page)
        }
    }

    /// All ingested-file rows projected as file nodes under the given view,
    /// ordered by id (ULID == ingest order). Resilient to the table not existing
    /// yet (pre-migration) → empty, so enumeration never errors.
    private static func ingestedFileNodes(byName: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let files = try? store.listAllIngestedFilesOrderedByID() else { return [] }
        return files.map { row in
            let id = byName ? Identity.fileByName(row.id) : Identity.fileByID(row.id)
            let summary = IngestedFileSummary(
                id: PageID(rawValue: row.id), filename: row.filename, ext: row.ext,
                mimeType: row.mime, byteSize: row.byteSize,
                createdAt: row.createdAt, updatedAt: row.updatedAt, version: row.version)
            return ingestedFileNode(for: id, file: summary)
        }
    }

    // MARK: - Content

    /// Materialize the bytes for a file identifier. README is static; page files
    /// read the live body from SQLite. Folders return nil.
    static func contents(for id: NSFileProviderItemIdentifier) -> Data? {
        if id == Identity.readme { return readmeBytes }
        // Generated index files: serve the SAME token-cached bytes whose length
        // `node(for:)` reported as `documentSize` (else `cat` truncates).
        if id == Identity.manifest || id == Identity.indexPagesJSONL
            || id == Identity.indexLinksJSONL || id == Identity.indexFilesJSONL {
            return indexData(for: id)
        }
        // Ingested files: serve the verbatim bytes from SQLite (raw, no
        // conversion). Resilient to a missing row/table → nil (noSuchItem).
        if let fileULID = Identity.fileULID(from: id) {
            guard let store = openReadStore(),
                  let data = try? store.ingestedFileContent(id: PageID(rawValue: fileULID)) else {
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
