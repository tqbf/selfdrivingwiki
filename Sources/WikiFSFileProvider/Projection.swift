import FileProvider
import Foundation
import WikiFSCore

/// The read-only SQLite-backed projection that replaces the spike's static
/// `Catalog`. Owns:
///   * the identity ↔ row mapping (virtual ids; paths are presentation only),
///   * the static `README.md` bytes,
///   * `node(for:)` / `children(of:)` / `contents(for:)`, each sharing ONE
///     short-lived read store per call (via `ReadScope` — #291); the app is
///     the only writer, and WAL + `query_only` reads are safe concurrently.
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

    /// Optional override for the wiki DB URL. Production (the File Provider
    /// extension) leaves this `nil` and resolves the wiki's DB via
    /// `DatabaseLocation` (the App Group container — unavailable outside the
    /// entitled sandbox). Tests inject a temp URL so the projection tree
    /// (`node`/`children`/`contents`) is exercisable end-to-end. Slice 2b: the
    /// projection previously had NO integration coverage for this reason.
    let databaseURL: URL?

    /// `databaseURL` defaults to `nil` (production resolves via `DatabaseLocation`).
    init(wikiID: String, databaseURL: URL? = nil) {
        self.wikiID = wikiID
        self.databaseURL = databaseURL
    }

    /// Request-scoped read-store cache. The public entry points
    /// (`children`/`node`/`contents`) set this on a scoped copy so every
    /// `openReadStore()` / `changeToken()` call within one logical operation
    /// reuses ONE SQLite connection + ONE token snapshot — collapsing the N+1
    /// store opens that made `children(of: .workingSet)` take 165 s+ (#291).
    /// Nil (the default) for standalone calls → each opens its own, as before.
    var readStoreHolder: ReadScope?

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

        // Chats (#119 follow-on): a top-level `chats/` tree with `by-id` and
        // `by-name` views, plus `indexes/chats.jsonl`. Each chat renders as a
        // readable `.md` transcript.
        static let chats = NSFileProviderItemIdentifier(WikiFSContainerID.chats)
        static let chatsByID = NSFileProviderItemIdentifier(WikiFSContainerID.chatsByID)
        static let chatsByName = NSFileProviderItemIdentifier(WikiFSContainerID.chatsByName)
        static let indexChatsJSONL = NSFileProviderItemIdentifier(WikiFSContainerID.indexChatsJSONL)
        static let chatByIDPrefix = WikiFSContainerID.chatByIDPrefix
        static let chatByNamePrefix = WikiFSContainerID.chatByNamePrefix

        // System prompt (v3): the same singleton document under two root-level
        // names (identical bytes) — `CLAUDE.md` and `AGENTS.md`.
        static let claudeMD = NSFileProviderItemIdentifier(WikiFSContainerID.claudeMD)
        static let agentsMD = NSFileProviderItemIdentifier(WikiFSContainerID.agentsMD)

        // Bookmarks (#125, Phase D): a top-level `bookmarks/` tree mirroring the
        // user-defined folder/ref structure. Folders and refs each carry the
        // bookmark-node ULID (NOT the target's ULID) so one bookmark can point
        // at the same page as another without colliding.
        static let bookmarks = NSFileProviderItemIdentifier(WikiFSContainerID.bookmarks)
        static let bookmarkFolderPrefix = WikiFSContainerID.bookmarkFolderPrefix
        static let bookmarkPageRefPrefix = WikiFSContainerID.bookmarkPageRefPrefix
        static let bookmarkSourceRefPrefix = WikiFSContainerID.bookmarkSourceRefPrefix
        static let bookmarkChatRefPrefix = WikiFSContainerID.bookmarkChatRefPrefix

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
        static let sourceByNamePrefix = WikiFSContainerID.sourceByNamePrefix
        static let sourceMarkdownByIDPrefix = "source-markdown-by-id:"
        static let sourceMarkdownByNamePrefix = "source-markdown-by-name:"

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

        static func sourceMarkdownByID(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(sourceMarkdownByIDPrefix + ulid)
        }

        static func sourceMarkdownByName(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(sourceMarkdownByNamePrefix + ulid)
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

        /// Extract the embedded ULID from a `source-markdown-by-id:` /
        /// `source-markdown-by-name:` identifier, or nil if it isn't a processed
        /// markdown head identifier.
        static func sourceMarkdownULID(from id: NSFileProviderItemIdentifier) -> String? {
            let raw = id.rawValue
            if raw.hasPrefix(sourceMarkdownByIDPrefix) { return String(raw.dropFirst(sourceMarkdownByIDPrefix.count)) }
            if raw.hasPrefix(sourceMarkdownByNamePrefix) { return String(raw.dropFirst(sourceMarkdownByNamePrefix.count)) }
            return nil
        }

        // MARK: Chat identifiers (#119 follow-on)

        static func chatByID(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(chatByIDPrefix + ulid)
        }

        static func chatByName(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(chatByNamePrefix + ulid)
        }

        /// Extract the embedded ULID from a `chat-by-id:` / `chat-by-name:`
        /// identifier, or nil if it isn't a chat identifier. The full ULID is in
        /// the identifier — never the filename (INITIAL §6).
        static func chatULID(from id: NSFileProviderItemIdentifier) -> String? {
            let raw = id.rawValue
            if raw.hasPrefix(chatByIDPrefix) { return String(raw.dropFirst(chatByIDPrefix.count)) }
            if raw.hasPrefix(chatByNamePrefix) { return String(raw.dropFirst(chatByNamePrefix.count)) }
            return nil
        }

        // MARK: Bookmark identifiers (Phase D)

        static func bookmarkFolder(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(bookmarkFolderPrefix + ulid)
        }
        static func bookmarkPageRef(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(bookmarkPageRefPrefix + ulid)
        }
        static func bookmarkSourceRef(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(bookmarkSourceRefPrefix + ulid)
        }
        static func bookmarkChatRef(_ ulid: String) -> NSFileProviderItemIdentifier {
            NSFileProviderItemIdentifier(bookmarkChatRefPrefix + ulid)
        }

        /// Extract the bookmark-node ULID from any bookmark identifier, or nil.
        static func bookmarkULID(from id: NSFileProviderItemIdentifier) -> String? {
            let raw = id.rawValue
            for p in [bookmarkFolderPrefix, bookmarkPageRefPrefix, bookmarkSourceRefPrefix, bookmarkChatRefPrefix] {
                if raw.hasPrefix(p) { return String(raw.dropFirst(p.count)) }
            }
            return nil
        }

        /// True if `id` is any bookmark identifier (folder or ref).
        static func isBookmark(_ id: NSFileProviderItemIdentifier) -> Bool {
            bookmarkULID(from: id) != nil
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
    - `bookmarks/`
    - `chats/by-id/`
    - `chats/by-name/`
    - `manifest.json`
    - `indexes/pages.jsonl`
    - `indexes/links.jsonl`
    - `indexes/sources.jsonl`
    - `indexes/chats.jsonl`

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

    /// Return the generated bytes for one index file at the current change
    /// token, regenerating (and caching) on a token miss. Looks up the matching
    /// `GeneratedIndex` descriptor and calls its generator. Returns nil only if
    /// no descriptor owns `id` or the DB is unavailable. Keyed by
    /// `(wikiID, identifier)` so two wikis sharing the process-wide cache never
    /// collide.
    private func indexData(for id: NSFileProviderItemIdentifier) -> Data? {
        guard let index = Self.generatedIndexes.first(where: { $0.id == id }) else { return nil }
        return Self.indexCache.data(forKey: "\(wikiID)/\(id.rawValue)", token: changeToken()) {
            index.generate(self)
        }
    }

    /// Build a file node for a generated index descriptor, sizing it from the
    /// SAME cached bytes `contents(for:)` will serve, and versioning it by the
    /// current token so the daemon re-fetches after any edit.
    private func indexFileNode(for index: GeneratedIndex) -> ProjectedNode? {
        guard let data = indexData(for: index.id) else { return nil }
        let version = Data(changeToken().utf8)
        return .file(id: index.id, parent: index.parent, name: index.name,
                     size: data.count, version: version, metadataVersion: version,
                     created: nil, modified: nil)
    }

    // MARK: - Read store

    /// A request-scoped cache for ONE read-only store + its change token. The
    /// public entry points (`children`/`node`/`contents`) create one of these on
    /// a scoped copy of the projection so every `openReadStore()` and
    /// `changeToken()` call within that operation reuses the same connection,
    /// instead of opening a fresh store (with pragma setup + vec0 registration
    /// + WAL checkpoint on close) for each leaf node (#291).
    ///
    /// Thread-safe (NSLock-guarded): the holder is a reference type shared
    /// across value-type projection copies, so the lock guards the lazy open
    /// and token cache even if two copies race (in practice each scope is
    /// single-threaded — one File Provider callback).
    final class ReadScope: @unchecked Sendable {
        private let databaseURL: URL?
        private let wikiID: String
        private let lock = NSLock()
        private var cachedStore: SQLiteWikiStore?
        private var cachedToken: String?

        init(databaseURL: URL?, wikiID: String) {
            self.databaseURL = databaseURL
            self.wikiID = wikiID
        }

        /// Lazily open ONE store; subsequent calls return the same connection.
        var store: SQLiteWikiStore? {
            lock.lock(); defer { lock.unlock() }
            if cachedStore == nil {
                let url = databaseURL ?? DatabaseLocation.extensionContainerURL(forWikiID: wikiID)
                if let url, FileManager.default.fileExists(atPath: url.path) {
                    DebugLog.fileprovider("ReadScope opening cached read-only connection wikiID=\(wikiID) thread=\(Thread.current)")
                    cachedStore = try? SQLiteWikiStore(readOnlyURL: url)
                }
            }
            return cachedStore
        }

        /// The cached token, or nil if not yet computed.
        var token: String? {
            lock.lock(); defer { lock.unlock() }
            return cachedToken
        }

        /// Cache the token (called once per scope, on first `changeToken()`).
        func cacheToken(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            cachedToken = value
        }
    }

    /// Open a read-only store at THIS wiki's `<ulid>.sqlite` in the App Group
    /// container. Within a read scope (`readStoreHolder` set) the SAME connection
    /// is reused for every call; outside a scope a fresh, short-lived store is
    /// opened each time (the historical behavior). Returns nil if the
    /// container/DB is unavailable.
    private func openReadStore() -> SQLiteWikiStore? {
        if let scope = readStoreHolder { return scope.store }
        let url = databaseURL ?? DatabaseLocation.extensionContainerURL(forWikiID: wikiID)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        DebugLog.fileprovider("openReadStore opening short-lived read-only connection wikiID=\(wikiID) thread=\(Thread.current)")
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
        let chatCount = (try? store?.listAllChatsOrderedByID())??.count ?? 0
        return Data(WikiTreeRenderer.render(pageCount: pageCount, sourceCount: sourceCount,
                                            chatCount: chatCount).utf8)
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
    ///
    /// Within a read scope the token is computed once and cached, so every node
    /// built during one enumeration pass gets a CONSISTENT version (previously
    /// each call queried independently, risking slight drift mid-pass) and avoids
    /// N redundant queries (#291).
    func changeToken() -> String {
        if let scope = readStoreHolder, let cached = scope.token {
            return cached
        }
        guard let store = openReadStore(),
              let token = try? store.changeToken() else { return "0:0" }
        readStoreHolder?.cacheToken(token)
        return token
    }

    // MARK: - Flat resource projections (slice 2b)

    /// Describes how one flat resource kind (`pages`, `sources`) projects onto
    /// the File Provider tree: a top-level folder holding two view containers
    /// (`by-id` + `by-name`/`by-title`), each enumerating its rows as leaf nodes.
    /// The generic `node`/`children`/`contents`/working-set logic iterates a
    /// registry of these (`flatProjections`) instead of switch-ing per kind, so a
    /// new flat kind is "add a descriptor", not "add four switch arms". (Phase D
    /// adds a nested descriptor shape for bookmarks.)
    ///
    /// Value type with closures, not a protocol w/ associated types: the
    /// per-kind store methods differ in signature, and only the dispatch varies
    /// (`owns`/`enumerate`/`nodeForLeaf`/`contentForLeaf`). The closures are
    /// same-file, so they may call `Projection`'s `private` read seam.
    struct FlatResourceProjection: @unchecked Sendable {
        let topLevel: NSFileProviderItemIdentifier
        let byIDContainer: NSFileProviderItemIdentifier
        let byNameContainer: NSFileProviderItemIdentifier
        /// Does this projection own `id` — a leaf under either view, including
        /// any sibling family (e.g. the source `.md` node)? Dispatches
        /// `node(for:)` / `contents(for:)`. Container identifiers return false.
        let owns: (NSFileProviderItemIdentifier) -> Bool
        /// Enumerate the leaf nodes for a view, ordered by ULID. 1 node/row for
        /// pages; 1 or 2 for sources (verbatim + optional `.md` sibling).
        let enumerate: (Projection, Bool /*isByName*/) -> [ProjectedNode]
        /// Resolve a single leaf node, or nil (for `node(for:)`).
        let nodeForLeaf: (Projection, NSFileProviderItemIdentifier) -> ProjectedNode?
        /// Serve the content bytes for a leaf, or nil (for `contents(for:)`).
        let contentForLeaf: (Projection, NSFileProviderItemIdentifier) -> Data?
    }

    static let pagesProjection = FlatResourceProjection(
        topLevel: Identity.pages,
        byIDContainer: Identity.pagesByID,
        byNameContainer: Identity.pagesByTitle,
        owns: { Identity.pageULID(from: $0) != nil },
        enumerate: { $0.pageNodes(byTitle: $1) },
        nodeForLeaf: { projection, id in
            guard let ulid = Identity.pageULID(from: id),
                  let store = projection.openReadStore(),
                  let page = try? store.getPage(id: PageID(rawValue: ulid)) else { return nil }
            // For by-title pages, size must match the rewritten bytes that
            // contents(for:) will serve — a mismatch truncates cat (#216).
            if id.rawValue.hasPrefix(Identity.byTitlePrefix) {
                let data = projection.byTitleContent(for: page, maps: projection.makeLinkMaps())
                return Self.pageFileNode(for: id, page: page, contentData: data)
            }
            return Self.pageFileNode(for: id, page: page)
        },
        contentForLeaf: { projection, id in
            guard let ulid = Identity.pageULID(from: id),
                  let store = projection.openReadStore(),
                  let page = try? store.getPage(id: PageID(rawValue: ulid)) else { return nil }
            // By-title view: rewrite [[wikilinks]] to relative Markdown links.
            if id.rawValue.hasPrefix(Identity.byTitlePrefix) {
                return projection.byTitleContent(for: page, maps: projection.makeLinkMaps())
            }
            return Data(PageMarkdownFormat.fileContent(for: page).utf8)
        }
    )

    static let sourcesProjection = FlatResourceProjection(
        topLevel: Identity.sources,
        byIDContainer: Identity.sourcesByID,
        byNameContainer: Identity.sourcesByName,
        // Owns both the verbatim source leaves and the `.md` sibling family.
        owns: { id in Identity.sourceMarkdownULID(from: id) != nil
                || Identity.fileULID(from: id) != nil },
        enumerate: { $0.sourceNodes(byName: $1) },
        nodeForLeaf: { projection, id in
            // Markdown sibling first (its prefix family is distinct from the
            // verbatim source prefixes, but checked first for clarity).
            if let ulid = Identity.sourceMarkdownULID(from: id) {
                guard let store = projection.openReadStore(),
                      let file = try? store.getSource(id: PageID(rawValue: ulid)),
                      let head = try? store.processedMarkdownHead(sourceID: PageID(rawValue: ulid)) else {
                    return nil
                }
                // For by-name markdown siblings, size must match rewritten bytes.
                if id.rawValue.hasPrefix(Identity.sourceMarkdownByNamePrefix) {
                    let data = projection.rewriteLinks(head.content, maps: projection.makeLinkMaps(),
                                                       baseDir: Self.sourcesByNameDir)
                    return Self.sourceMarkdownNode(for: id, source: file, head: head, contentData: data)
                }
                return Self.sourceMarkdownNode(for: id, source: file, head: head)
            }
            if let ulid = Identity.fileULID(from: id) {
                guard let store = projection.openReadStore(),
                      let file = try? store.getSource(id: PageID(rawValue: ulid)) else { return nil }
                if id.rawValue.hasPrefix(Identity.sourceByNamePrefix) {
                    let contentData = projection.rewrittenVerbatimSourceContent(
                        id: PageID(rawValue: ulid), mimeType: file.mimeType,
                        maps: projection.makeLinkMaps())
                    return Self.sourceNode(for: id, file: file, contentData: contentData)
                }
                return Self.sourceNode(for: id, file: file)
            }
            return nil
        },
        contentForLeaf: { projection, id in
            if let ulid = Identity.sourceMarkdownULID(from: id) {
                guard let store = projection.openReadStore(),
                      let head = try? store.processedMarkdownHead(sourceID: PageID(rawValue: ulid)) else {
                    return nil
                }
                // Wrap with provenance frontmatter (#131).
                let wrapped = SourceMarkdownFormat.fileContent(for: head)
                // By-name markdown siblings: rewrite [[wikilinks]] to relative links.
                if id.rawValue.hasPrefix(Identity.sourceMarkdownByNamePrefix) {
                    return projection.rewriteLinks(wrapped, maps: projection.makeLinkMaps(),
                                                   baseDir: Self.sourcesByNameDir)
                }
                return Data(wrapped.utf8)
            }
            if let ulid = Identity.fileULID(from: id) {
                guard let store = projection.openReadStore(),
                      let file = try? store.getSource(id: PageID(rawValue: ulid)),
                      let data = try? store.sourceContent(id: PageID(rawValue: ulid)) else { return nil }
                if id.rawValue.hasPrefix(Identity.sourceByNamePrefix),
                   let rewritten = projection.rewrittenVerbatimSourceContent(
                       id: PageID(rawValue: ulid), mimeType: file.mimeType,
                       maps: projection.makeLinkMaps()) {
                    return rewritten
                }
                return data
            }
            return nil
        }
    )

    static let chatsProjection = FlatResourceProjection(
        topLevel: Identity.chats,
        byIDContainer: Identity.chatsByID,
        byNameContainer: Identity.chatsByName,
        owns: { Identity.chatULID(from: $0) != nil },
        enumerate: { $0.chatNodes(byName: $1) },
        nodeForLeaf: { projection, id in
            guard let ulid = Identity.chatULID(from: id),
                  let store = projection.openReadStore(),
                  let chats = try? store.listAllChatsOrderedByID(),
                  let chat = chats.first(where: { $0.id.rawValue == ulid }) else { return nil }
            // For by-name chats, size must match rewritten bytes.
            if id.rawValue.hasPrefix(Identity.chatByNamePrefix) {
                let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
                let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
                let data = projection.rewriteLinks(raw, maps: projection.makeLinkMaps(),
                                                   baseDir: Self.chatsByNameDir)
                return Self.chatFileNode(for: id, chat: chat, in: store, contentData: data)
            }
            return Self.chatFileNode(for: id, chat: chat, in: store)
        },
        contentForLeaf: { projection, id in
            guard let ulid = Identity.chatULID(from: id),
                  let store = projection.openReadStore(),
                  let chats = try? store.listAllChatsOrderedByID(),
                  let chat = chats.first(where: { $0.id.rawValue == ulid }),
                  let messages = try? store.chatMessages(chatID: chat.id) else { return nil }
            let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
            // By-name chats: rewrite [[wikilinks]] to relative links.
            if id.rawValue.hasPrefix(Identity.chatByNamePrefix) {
                return projection.rewriteLinks(raw, maps: projection.makeLinkMaps(),
                                               baseDir: Self.chatsByNameDir)
            }
            return Data(raw.utf8)
        }
    )

    /// The flat-resource projections, in tree order (pages before sources —
    /// matches the historical root/working-set layout). `node`/`children`/
    /// `contents`/working-set iterate this.
    static let flatProjections: [FlatResourceProjection] = [pagesProjection, sourcesProjection, chatsProjection]

    // MARK: - Singleton-doc + generated-index projections (slice 2b, Phase C)

    /// Describes a root-level singleton document — one logical doc that may
    /// appear under one or more filenames (e.g. CLAUDE.md + AGENTS.md serve the
    /// identical system prompt; WIKI-STRUCTURE.md + TREE.md serve the identical
    /// layout map). Mirrors `FlatResourceProjection` (Phase B): the dispatch
    /// sites (`node`/`children`/`contents`/working set) iterate a registry of
    /// these instead of switch-ing per doc, so a new singleton doc is "add a
    /// descriptor", not "add switch arms + a bespoke builder".
    ///
    /// Value type with closures, not a protocol w/ associated types (D2): only
    /// the dispatch varies (`nodeFor`/`contentFor`). The closures are same-file,
    /// so they may call `Projection`'s `private` read seam.
    struct SingletonDocEntry: Sendable {
        let id: NSFileProviderItemIdentifier
        let name: String
    }

    struct SingletonDoc: @unchecked Sendable {
        /// The root-level filename(s). One entry for a single-name doc; two for
        /// a dual-name alias (CLAUDE.md/AGENTS.md, WIKI-STRUCTURE.md/TREE.md).
        let entries: [SingletonDocEntry]
        /// Build the file node for one entry's identifier + name, or nil.
        let nodeFor: (Projection, NSFileProviderItemIdentifier, String) -> ProjectedNode?
        /// Serve the content bytes (identical for all aliases of one doc).
        let contentFor: (Projection) -> Data?
        /// Whether this doc participates in the working set. Static docs (README
        /// — constant bytes, constant version) never change, so the daemon need
        /// not track them for invalidation.
        let participatesInWorkingSet: Bool
    }

    /// Describes one generated index file (manifest.json, *.jsonl). Already
    /// deduplicated via the shared token-keyed `IndexCache` + `indexFileNode`;
    /// Phase C collects the per-file variation (identifier, filename, parent,
    /// generator) into a descriptor so the dispatch sites iterate a registry,
    /// matching `SingletonDoc` / `FlatResourceProjection`.
    struct GeneratedIndex: @unchecked Sendable {
        let id: NSFileProviderItemIdentifier
        let name: String
        let parent: NSFileProviderItemIdentifier
        /// Generate the raw bytes from a fresh read store (uncached; `indexData`
        /// caches the result keyed by the current token).
        let generate: (Projection) -> Data?
    }

    // --- Singleton-doc instances ---

    static let readmeDoc = SingletonDoc(
        entries: [.init(id: Identity.readme, name: "README.md")],
        nodeFor: { _, id, name in
            .file(id: id, parent: .rootContainer, name: name,
                  size: Self.readmeBytes.count, version: Self.staticVersion,
                  metadataVersion: Self.staticVersion, created: nil, modified: nil)
        },
        contentFor: { _ in Self.readmeBytes },
        participatesInWorkingSet: false
    )

    static let systemPromptDoc = SingletonDoc(
        entries: [.init(id: Identity.claudeMD, name: "CLAUDE.md"),
                  .init(id: Identity.agentsMD, name: "AGENTS.md")],
        nodeFor: { $0.systemPromptNode(for: $1, name: $2) },
        contentFor: { Data($0.systemPromptDocument().body.utf8) },
        participatesInWorkingSet: true
    )

    static let wikiIndexDoc = SingletonDoc(
        entries: [.init(id: Identity.indexMD, name: "index.md")],
        nodeFor: { projection, id, _ in projection.wikiIndexNode(for: id) },
        contentFor: { Data($0.wikiIndexDocument().body.utf8) },
        participatesInWorkingSet: true
    )

    static let logDoc = SingletonDoc(
        entries: [.init(id: Identity.logMD, name: "log.md")],
        nodeFor: { projection, id, _ in projection.logNode(for: id) },
        contentFor: { $0.logBody() },
        participatesInWorkingSet: true
    )

    static let wikiStructureDoc = SingletonDoc(
        entries: [.init(id: Identity.wikiStructureMD, name: "WIKI-STRUCTURE.md"),
                  .init(id: Identity.treeMD, name: "TREE.md")],
        nodeFor: { $0.treeNode(for: $1, name: $2) },
        contentFor: { $0.treeBody() },
        participatesInWorkingSet: true
    )

    /// Singleton docs in root-tree order (README first, matching the historical
    /// layout). `node`/`children`/`contents`/working-set iterate this.
    static let singletonDocs: [SingletonDoc] = [
        readmeDoc, systemPromptDoc, wikiIndexDoc, logDoc, wikiStructureDoc
    ]

    // --- Generated-index instances ---

    static let manifestIndex = GeneratedIndex(
        id: Identity.manifest, name: "manifest.json", parent: .rootContainer,
        generate: { projection in
            guard let store = projection.openReadStore(),
                  let pages = try? store.listAllPagesOrderedByID() else { return nil }
            // file_count must be resilient to a pre-migration `ingested_files`:
            // a `nil` read → 0, so the manifest still generates.
            let sourceCount = (try? store.listAllSourcesOrderedByID())?.count ?? 0
            let chatCount = (try? store.listAllChatsOrderedByID())?.count ?? 0
            return IndexGenerators.manifest(pages: pages, sourceCount: sourceCount,
                                            chatCount: chatCount, generatedAt: Date())
        }
    )

    static let pagesJSONLIndex = GeneratedIndex(
        id: Identity.indexPagesJSONL, name: "pages.jsonl", parent: Identity.indexes,
        generate: { projection in
            guard let store = projection.openReadStore(),
                  let pages = try? store.listAllPagesOrderedByID() else { return nil }
            return IndexGenerators.pagesJSONL(pages: pages)
        }
    )

    static let linksJSONLIndex = GeneratedIndex(
        id: Identity.indexLinksJSONL, name: "links.jsonl", parent: Identity.indexes,
        generate: { projection in
            guard let store = projection.openReadStore(),
                  let pageLinks = try? store.listAllLinks(),
                  let sourceLinks = try? store.listAllSourceLinks() else { return nil }
            // Page rows first, then source rows — each already sorted by (from,to).
            return IndexGenerators.linksJSONL(links: pageLinks + sourceLinks)
        }
    )

    static let sourcesJSONLIndex = GeneratedIndex(
        id: Identity.indexSourcesJSONL, name: "sources.jsonl", parent: Identity.indexes,
        generate: { projection in
            guard let store = projection.openReadStore() else { return nil }
            // Resilient to the table not existing yet → empty index, never nil,
            // so enumeration of `indexes/` never errors pre-migration.
            let files = (try? store.listAllSourcesOrderedByID()) ?? []
            return IndexGenerators.sourcesJSONL(sources: files)
        }
    )

    static let chatsJSONLIndex = GeneratedIndex(
        id: Identity.indexChatsJSONL, name: "chats.jsonl", parent: Identity.indexes,
        generate: { projection in
            guard let store = projection.openReadStore() else { return nil }
            // Resilient to the `chats` table not existing yet → empty index,
            // never nil, so enumeration of `indexes/` never errors pre-migration.
            let chats = (try? store.listAllChatsOrderedByID()) ?? []
            return IndexGenerators.chatsJSONL(chats: chats)
        }
    )

    /// Generated indexes in tree order. Root-level files (manifest.json) have
    /// `parent == .rootContainer`; JSONL files live under `indexes/`. The root
    /// and `indexes/` children lists filter on `parent`.
    static let generatedIndexes: [GeneratedIndex] = [
        manifestIndex, pagesJSONLIndex, linksJSONLIndex, sourcesJSONLIndex, chatsJSONLIndex
    ]

    // MARK: - Nested resource projections (slice 2b, Phase D)

    /// Describes a nested (folder-tree) resource projection — a top-level
    /// folder containing user-defined subfolders and leaf refs, like bookmarks.
    /// Mirrors `FlatResourceProjection` (Phase B) / `SingletonDoc` (Phase C):
    /// the dispatch sites iterate a registry of these. The key difference from a
    /// flat projection is that nesting is arbitrary-depth: `childrenOf` resolves
    /// any container (the topLevel or a folder) to its children.
    ///
    /// Value type with closures, not a protocol w/ associated types (D2). The
    /// closures are same-file, so they may call `Projection`'s `private` seam.
    struct NestedResourceProjection: @unchecked Sendable {
        let topLevel: NSFileProviderItemIdentifier
        /// Does this projection own `id` — any node (folder or leaf) in this tree?
        let owns: (NSFileProviderItemIdentifier) -> Bool
        /// Resolve a single node by identifier (folder or leaf), or nil.
        let nodeFor: (Projection, NSFileProviderItemIdentifier) -> ProjectedNode?
        /// Enumerate the children of a container (topLevel or a folder). Returns
        /// `[]` for leaf identifiers (they have no children).
        let childrenOf: (Projection, NSFileProviderItemIdentifier) -> [ProjectedNode]
        /// Serve content bytes for a leaf identifier, or nil.
        let contentFor: (Projection, NSFileProviderItemIdentifier) -> Data?
        /// Emit ALL nodes at every depth (for the working set).
        let allNodes: (Projection) -> [ProjectedNode]
    }

    static let bookmarksProjection = NestedResourceProjection(
        topLevel: Identity.bookmarks,
        owns: { Identity.isBookmark($0) },
        nodeFor: { $0.bookmarkNode(for: $1) },
        childrenOf: { $0.bookmarkChildren(of: $1) },
        contentFor: { $0.bookmarkContent(for: $1) },
        allNodes: { $0.allBookmarkNodes() }
    )

    /// Nested-resource projections, in tree order. `node`/`children`/`contents`/
    /// working-set iterate this.
    static let nestedProjections: [NestedResourceProjection] = [bookmarksProjection]

    // MARK: - Bookmark projection helpers (Phase D)

    /// Map a `BookmarkNode` to its File Provider identifier (kind-dispatched).
    static func bookmarkID(for node: BookmarkNode) -> NSFileProviderItemIdentifier {
        switch node.kind {
        case .folder:      return Identity.bookmarkFolder(node.id)
        case .pageRef:     return Identity.bookmarkPageRef(node.id)
        case .sourceRef:   return Identity.bookmarkSourceRef(node.id)
        case .chatRef:     return Identity.bookmarkChatRef(node.id)
        }
    }

    /// Resolve the File Provider parent identifier for a bookmark node (root →
    /// the `bookmarks` folder; nested → the parent's folder identifier).
    static func bookmarkParent(for node: BookmarkNode) -> NSFileProviderItemIdentifier {
        if let parentID = node.parentID {
            return Identity.bookmarkFolder(parentID)
        }
        return Identity.bookmarks
    }

    /// Replace the path separator in a display name (folders are virtual, but
    /// Finder/Terminal users see the name).
    static func sanitizeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }

    /// The projection-relative directory components CONTAINING `node` —
    /// `["bookmarks"]` for a root-level ref, plus one sanitized label per
    /// ancestor folder (root → immediate parent). Used as the rewriter's
    /// `baseDir` so a nested ref's links climb the right number of `../`.
    /// The parent walk is capped (matches `BookmarkNode.displayPath`) so a
    /// corrupted parent cycle can't loop forever.
    private func bookmarkBaseDir(for node: BookmarkNode,
                                 in nodes: [BookmarkNode]) -> [String] {
        var byID: [String: BookmarkNode] = [:]
        byID.reserveCapacity(nodes.count)
        for n in nodes { byID[n.id] = n }

        var labels: [String] = []
        var current = node.parentID.flatMap { byID[$0] }
        var depth = 0
        let maxDepth = 64
        while let folder = current, depth < maxDepth {
            depth += 1
            labels.insert(Self.sanitizeFilename(folder.label ?? "Untitled"), at: 0)
            current = folder.parentID.flatMap { byID[$0] }
        }
        return ["bookmarks"] + labels
    }

    /// Build a `ProjectedNode` for one bookmark node, resolving the target for
    /// refs. Stale refs (target deleted) render as a small placeholder file so
    /// the tree shape is preserved. All bookmark nodes are versioned by the
    /// change token so any mutation re-fetches them.
    private func bookmarkNodeItem(
        for node: BookmarkNode, in store: SQLiteWikiStore,
        maps: LinkMaps, allNodes: [BookmarkNode]
    ) -> ProjectedNode {
        let id = Self.bookmarkID(for: node)
        let parent = Self.bookmarkParent(for: node)
        let version = Data(changeToken().utf8)
        switch node.kind {
        case .folder:
            return .folder(id: id, parent: parent, name: node.label ?? "Untitled")
        case .pageRef:
            if let targetID = node.targetID,
               let page = try? store.getPage(id: targetID) {
                let baseDir = bookmarkBaseDir(for: node, in: allNodes)
                let body = rewriteLinks(PageMarkdownFormat.fileContent(for: page),
                                        maps: maps, baseDir: baseDir)
                let name = Self.sanitizeFilename(page.title) + ".md"
                return .file(id: id, parent: parent, name: name, size: body.count,
                             version: version, metadataVersion: version,
                             created: page.createdAt, modified: page.updatedAt)
            }
            let body = Data("# Stale reference\n\nThis bookmark points to a deleted page.".utf8)
            return .file(id: id, parent: parent, name: "Stale Reference.md",
                         size: body.count, version: version, metadataVersion: version,
                         created: nil, modified: nil)
        case .sourceRef:
            if let targetID = node.targetID,
               let source = try? store.getSource(id: targetID) {
                let humanName = source.displayName ?? source.filename
                return .file(id: id, parent: parent,
                             name: Self.sanitizeFilename(humanName),
                             size: source.byteSize,
                             version: version, metadataVersion: version,
                             created: source.createdAt, modified: source.updatedAt,
                             ingestedExt: source.ext, mimeType: source.mimeType)
            }
            let body = Data("# Stale reference\n\nThis bookmark points to a deleted source.".utf8)
            return .file(id: id, parent: parent, name: "Stale Reference.txt",
                         size: body.count, version: version, metadataVersion: version,
                         created: nil, modified: nil)
        case .chatRef:
            if let targetID = node.targetID,
               let chat = (try? store.listAllChatsOrderedByID())?.first(where: { $0.id == targetID }) {
                let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
                let baseDir = bookmarkBaseDir(for: node, in: allNodes)
                let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
                let body = rewriteLinks(raw, maps: maps, baseDir: baseDir)
                let name = Self.sanitizeFilename(chat.title) + ".md"
                return .file(id: id, parent: parent, name: name, size: body.count,
                             version: version, metadataVersion: version,
                             created: chat.createdAt, modified: chat.updatedAt)
            }
            let body = Data("# Stale reference\n\nThis bookmark points to a deleted chat.".utf8)
            return .file(id: id, parent: parent, name: "Stale Reference.md",
                         size: body.count, version: version, metadataVersion: version,
                         created: nil, modified: nil)
        }
    }

    /// Resolve a single bookmark node by identifier (for `node(for:)`).
    private func bookmarkNode(for id: NSFileProviderItemIdentifier) -> ProjectedNode? {
        guard let ulid = Identity.bookmarkULID(from: id),
              let store = openReadStore(),
              let nodes = try? store.listBookmarkNodes(),
              let node = nodes.first(where: { $0.id == ulid }) else { return nil }
        return bookmarkNodeItem(for: node, in: store, maps: makeLinkMaps(), allNodes: nodes)
    }

    /// Enumerate the children of a bookmark container (the topLevel folder or a
    /// nested folder). Leaf identifiers return `[]`.
    private func bookmarkChildren(of container: NSFileProviderItemIdentifier) -> [ProjectedNode] {
        let parentID: String?
        if container == Identity.bookmarks {
            parentID = nil
        } else if container.rawValue.hasPrefix(Identity.bookmarkFolderPrefix),
                  let ulid = Identity.bookmarkULID(from: container) {
            parentID = ulid
        } else {
            return []
        }
        guard let store = openReadStore(),
              let nodes = try? store.listBookmarkNodes() else { return [] }
        let maps = makeLinkMaps()
        return nodes
            .filter { $0.parentID == parentID }
            .sorted { $0.position < $1.position }
            .compactMap { bookmarkNodeItem(for: $0, in: store, maps: maps, allNodes: nodes) }
    }

    /// Serve content for a bookmark ref leaf, resolving the target. Folders
    /// return nil. Stale refs serve a placeholder.
    private func bookmarkContent(for id: NSFileProviderItemIdentifier) -> Data? {
        guard let ulid = Identity.bookmarkULID(from: id),
              let store = openReadStore(),
              let nodes = try? store.listBookmarkNodes(),
              let node = nodes.first(where: { $0.id == ulid }) else { return nil }
        switch node.kind {
        case .folder:
            return nil
        case .pageRef:
            guard let targetID = node.targetID,
                  let page = try? store.getPage(id: targetID) else {
                return Data("# Stale reference\n\nThis bookmark points to a deleted page.".utf8)
            }
            return rewriteLinks(PageMarkdownFormat.fileContent(for: page),
                                maps: makeLinkMaps(),
                                baseDir: bookmarkBaseDir(for: node, in: nodes))
        case .sourceRef:
            guard let targetID = node.targetID else {
                return Data("# Stale reference\n\nThis bookmark points to a deleted source.".utf8)
            }
            return (try? store.sourceContent(id: targetID))
                ?? Data("# Stale reference\n\nThis bookmark points to a deleted source.".utf8)
        case .chatRef:
            guard let targetID = node.targetID,
                  let chat = (try? store.listAllChatsOrderedByID())?.first(where: { $0.id == targetID }) else {
                return Data("# Stale reference\n\nThis bookmark points to a deleted chat.".utf8)
            }
            let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
            let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
            return rewriteLinks(raw, maps: makeLinkMaps(),
                                baseDir: bookmarkBaseDir(for: node, in: nodes))
        }
    }

    /// Emit ALL bookmark nodes at every depth (for the working set).
    private func allBookmarkNodes() -> [ProjectedNode] {
        guard let store = openReadStore(),
              let nodes = try? store.listBookmarkNodes() else { return [] }
        let maps = makeLinkMaps()
        return nodes.compactMap { bookmarkNodeItem(for: $0, in: store, maps: maps, allNodes: nodes) }
    }

    // MARK: - Metadata resolution

    /// Resolve a single item's metadata by identifier. Opens ONE shared read
    /// store for the whole resolution (including any change-token reads),
    /// collapsing what was previously 1–3 independent store opens per call.
    func node(for id: NSFileProviderItemIdentifier) -> ProjectedNode? {
        var scoped = self
        scoped.readStoreHolder = ReadScope(databaseURL: databaseURL, wikiID: wikiID)
        return scoped.nodeResolved(for: id)
    }

    /// Store-sharing implementation of `node(for:)`. Called on a scoped copy
    /// carrying a `ReadScope` so every `openReadStore()` / `changeToken()` within
    /// this resolution reuses one connection (#291).
    private func nodeResolved(for id: NSFileProviderItemIdentifier) -> ProjectedNode? {
        if id == .rootContainer {
            return .folder(id: .rootContainer, parent: .rootContainer, name: "Self Driving Wiki")
        }
        // Singleton docs (slice 2b Phase C): dispatch to the matching doc entry.
        for doc in Self.singletonDocs {
            if let entry = doc.entries.first(where: { $0.id == id }) {
                return doc.nodeFor(self, id, entry.name)
            }
        }
        // Generated indexes (slice 2b Phase C): dispatch to the matching index.
        for index in Self.generatedIndexes where index.id == id {
            return indexFileNode(for: index)
        }
        // Structural folders (per-kind — not resource-driven).
        switch id {
        case Identity.pages:
            return .folder(id: id, parent: .rootContainer, name: "pages")
        case Identity.pagesByID:
            return .folder(id: id, parent: Identity.pages, name: "by-id")
        case Identity.pagesByTitle:
            return .folder(id: id, parent: Identity.pages, name: "by-title")
        case Identity.indexes:
            return .folder(id: id, parent: .rootContainer, name: "indexes")
        case Identity.bookmarks:
            return .folder(id: id, parent: .rootContainer, name: "bookmarks")
        case Identity.sources:
            return .folder(id: id, parent: .rootContainer, name: "sources")
        case Identity.sourcesByID:
            return .folder(id: id, parent: Identity.sources, name: "by-id")
        case Identity.sourcesByName:
            return .folder(id: id, parent: Identity.sources, name: "by-name")
        case Identity.chats:
            return .folder(id: id, parent: .rootContainer, name: "chats")
        case Identity.chatsByID:
            return .folder(id: id, parent: Identity.chats, name: "by-id")
        case Identity.chatsByName:
            return .folder(id: id, parent: Identity.chats, name: "by-name")
        default:
            break
        }
        // Flat leaf resolution (slice 2b Phase B): dispatch to the owning
        // flat-resource projection. Each projection's `owns(_:)` recognizes its
        // own leaf identifier families (page-by-id/title, source-by-id/name,
        // and the source-markdown sibling); container identifiers return nil.
        for projection in Self.flatProjections where projection.owns(id) {
            return projection.nodeForLeaf(self, id)
        }
        // Nested leaf/folder resolution (slice 2b Phase D).
        for projection in Self.nestedProjections where projection.owns(id) {
            return projection.nodeFor(self, id)
        }
        return nil
    }

    /// Build a file node for a processed markdown head (the `.md` sibling of a
    /// verbatim source, projected under both `by-id` and `by-name` views).
    /// Always has `ingestedExt:"md"`; versioned by the head's ULID so any
    /// edit/revert bumps the item version and invalidates the daemon's cache.
    static func sourceMarkdownNode(
        for id: NSFileProviderItemIdentifier,
        source: SourceSummary,
        head: SourceMarkdownVersion,
        contentData: Data? = nil
    ) -> ProjectedNode {
        let raw = id.rawValue
        let isByName = raw.hasPrefix(Identity.sourceMarkdownByNamePrefix)
        let humanName = source.displayName ?? source.filename
        let name = isByName
            ? FilenameEscaping.byNameSourceFilename(
                filename: humanName, ext: "md", sourceID: source.id.rawValue)
            : FilenameEscaping.byIDSourceFilename(sourceID: source.id.rawValue, ext: "md")
        let parent = isByName ? Identity.sourcesByName : Identity.sourcesByID
        let size = contentData?.count ?? head.content.utf8.count
        return .file(
            id: id, parent: parent, name: name, size: size,
            version: Data(head.id.rawValue.utf8),
            metadataVersion: Data(head.id.rawValue.utf8),
            created: head.createdAt, modified: head.createdAt,
            ingestedExt: "md",
            mimeType: "text/markdown"
        )
    }

    /// Build a file node for an ingested-file row, under whichever view `id`
    /// belongs to. Size is the stored `byteSize` (NEVER nil → no truncated
    /// `cat`); contentVersion is the row `version`; metadataVersion folds in the
    /// display name (or filename fallback) + updated_at so a rename re-fetches
    /// the by-name node. By-id stays filename-keyed (stable identity).
    static func sourceNode(for id: NSFileProviderItemIdentifier,
                                 file: SourceSummary,
                                 contentData: Data? = nil) -> ProjectedNode {
        let raw = id.rawValue
        let isByName = raw.hasPrefix(Identity.sourceByNamePrefix)
        let humanName = file.displayName ?? file.filename
        let name = isByName
            ? FilenameEscaping.byNameSourceFilename(
                filename: humanName, ext: file.ext, sourceID: file.id.rawValue)
            : FilenameEscaping.byIDSourceFilename(sourceID: file.id.rawValue, ext: file.ext)
        let parent = isByName ? Identity.sourcesByName : Identity.sourcesByID
        let metaKey = isByName
            ? "\(humanName)|\(file.updatedAt.timeIntervalSince1970)|\(file.version)"
            : "\(file.filename)|\(file.updatedAt.timeIntervalSince1970)|\(file.version)"
        return .file(
            id: id, parent: parent, name: name, size: contentData?.count ?? file.byteSize,
            version: Data(String(file.version).utf8),
            metadataVersion: Data(metaKey.utf8),
            created: file.createdAt, modified: file.updatedAt,
            ingestedExt: file.ext,
            mimeType: file.mimeType
        )
    }

    /// Build a file node for a page row, under whichever view `id` belongs to.
    /// Pass `contentData` when the caller has already computed the rewritten
    /// bytes (by-title view) so the reported `documentSize` matches what
    /// `contents(for:)` will serve — a mismatch truncates `cat`.
    static func pageFileNode(for id: NSFileProviderItemIdentifier,
                             page: WikiPage,
                             contentData: Data? = nil) -> ProjectedNode {
        let raw = id.rawValue
        let isByTitle = raw.hasPrefix(Identity.byTitlePrefix)
        let name = isByTitle
            ? FilenameEscaping.byTitleFilename(title: page.title, pageID: page.id.rawValue)
            : FilenameEscaping.byIDFilename(pageID: page.id.rawValue)
        let parent = isByTitle ? Identity.pagesByTitle : Identity.pagesByID
        let fileData = contentData ?? Data(PageMarkdownFormat.fileContent(for: page).utf8)
        return .file(
            id: id, parent: parent, name: name, size: fileData.count,
            version: Data(String(page.version).utf8),
            metadataVersion: Data(
                "\(page.title)|\(page.updatedAt.timeIntervalSince1970)|\(page.version)".utf8),
            created: page.createdAt, modified: page.updatedAt
        )
    }

    // MARK: - Link rewriting (by-title / by-name views)

    /// Root-relative directory of each projected view, matching the FileProvider
    /// tree. These are the `baseDir` / target-path prefixes the rewriter uses to
    /// compute relative link destinations across namespaces.
    static let pagesByTitleDir  = ["pages", "by-title"]
    static let sourcesByNameDir = ["sources", "by-name"]
    static let chatsByNameDir   = ["chats", "by-name"]

    /// The six title/id → target maps the rewriter resolves against, built once
    /// from the store. Keys: page/chat by title, source by human name, and each
    /// by uppercased ULID (canonical `[[page:<ULID>]]` form). A `resolver` for a
    /// given document `baseDir` closes over these to relativize each target path.
    struct LinkMaps {
        let pageByTitle:  [String: RelativeLinkRewriter.Target]
        let pageByID:     [String: RelativeLinkRewriter.Target]
        let sourceByName: [String: RelativeLinkRewriter.Target]
        let sourceByID:   [String: RelativeLinkRewriter.Target]
        let chatByTitle:  [String: RelativeLinkRewriter.Target]
        let chatByID:     [String: RelativeLinkRewriter.Target]
        let siblingImages: [PageID: [String: PageID]]   // sourceID -> [originalPath -> sibling sourceID]

        func resolver(baseDir: [String]) -> RelativeLinkRewriter.Resolver {
            RelativeLinkRewriter.Resolver(
                baseDir: baseDir,
                page:   { t, isID in isID ? pageByID[t.uppercased()]   : pageByTitle[t] },
                source: { t, isID in isID ? sourceByID[t.uppercased()] : sourceByName[t] },
                chat:   { t, isID in isID ? chatByID[t.uppercased()]   : chatByTitle[t] }
            )
        }

        /// The image-src resolver for ONE source's own markdown, or an
        /// always-nil resolver if it has no image siblings (the common case —
        /// most sources never call this at all, gated by the caller).
        func imageResolver(forSource sourceID: PageID, baseDir: [String]) -> SourceImageRewriter.Resolver {
            let siblingMap = siblingImages[sourceID] ?? [:]
            return SourceImageRewriter.Resolver(baseDir: baseDir, resolve: { originalPath in
                guard let siblingID = siblingMap[originalPath] else { return nil }
                return sourceByID[siblingID.rawValue.uppercased()]
            })
        }
    }

    /// Build the link-resolution maps from the shared read store. Resilient to
    /// pre-migration tables (missing → empty map → links left `[[…]]` verbatim).
    /// Source links target the readable `.md` sibling when one exists, else the
    /// verbatim file — matching the file that `sourceNodes` actually projects.
    private func makeLinkMaps() -> LinkMaps {
        let store = openReadStore()

        var pageByTitle: [String: RelativeLinkRewriter.Target] = [:]
        var pageByID: [String: RelativeLinkRewriter.Target] = [:]
        for page in (try? store?.listAllPagesOrderedByID()) ?? [] {
            let file = FilenameEscaping.byTitleFilename(title: page.title, pageID: page.id.rawValue)
            let target = RelativeLinkRewriter.Target(path: Self.pagesByTitleDir + [file], title: page.title)
            pageByTitle[page.title] = target
            pageByID[page.id.rawValue.uppercased()] = target
        }

        var sourceByName: [String: RelativeLinkRewriter.Target] = [:]
        var sourceByID: [String: RelativeLinkRewriter.Target] = [:]
        let heads = (try? store?.processedMarkdownHeadsBySource()) ?? [:]
        for row in (try? store?.listAllSourcesOrderedByID()) ?? [] {
            let humanName = row.displayName ?? row.filename
            // Sibling eligibility mirrors `sourceNodes`: a processed head AND a
            // non-`text/*` mime yields the `.md` sibling; otherwise the verbatim file.
            let hasSibling = heads[row.id] != nil && (row.mime.map { !$0.hasPrefix("text/") } ?? false)
            let file = hasSibling
                ? FilenameEscaping.byNameSourceFilename(filename: humanName, ext: "md", sourceID: row.id)
                : FilenameEscaping.byNameSourceFilename(filename: humanName, ext: row.ext, sourceID: row.id)
            let target = RelativeLinkRewriter.Target(path: Self.sourcesByNameDir + [file], title: humanName)
            sourceByName[humanName] = target
            sourceByID[row.id.uppercased()] = target
        }

        var chatByTitle: [String: RelativeLinkRewriter.Target] = [:]
        var chatByID: [String: RelativeLinkRewriter.Target] = [:]
        for chat in (try? store?.listAllChatsOrderedByID()) ?? [] {
            let file = FilenameEscaping.byTitleFilename(title: chat.title, pageID: chat.id.rawValue)
            let target = RelativeLinkRewriter.Target(path: Self.chatsByNameDir + [file], title: chat.title)
            chatByTitle[chat.title] = target
            chatByID[chat.id.rawValue.uppercased()] = target
        }

        let siblingImages = (try? store?.siblingImageResolvers()) ?? [:]

        return LinkMaps(pageByTitle: pageByTitle, pageByID: pageByID,
                        sourceByName: sourceByName, sourceByID: sourceByID,
                        chatByTitle: chatByTitle, chatByID: chatByID,
                        siblingImages: siblingImages)
    }

    /// Rewrite `[[wikilinks]]` in `raw` to relative Markdown links, computing
    /// destinations relative to `baseDir` (the document's own directory). Single
    /// source of truth for both `documentSize` and served bytes — a mismatch
    /// truncates `cat`, so every size/content pair must share this.
    private func rewriteLinks(_ raw: String, maps: LinkMaps, baseDir: [String]) -> Data {
        Data(RelativeLinkRewriter.rewrite(raw, resolver: maps.resolver(baseDir: baseDir)).utf8)
    }

    /// The rewritten by-title page content (page bodies live in `pages/by-title`).
    private func byTitleContent(for page: WikiPage, maps: LinkMaps) -> Data {
        rewriteLinks(PageMarkdownFormat.fileContent(for: page), maps: maps, baseDir: Self.pagesByTitleDir)
    }

    /// Rewrite relative image srcs in a markdown-native verbatim source's own
    /// content, IF it has image siblings (`makeLinkMaps().siblingImages`).
    /// Returns `nil` when there's nothing to rewrite (binary sources, sources
    /// with no image siblings, or non-`by-name` requests) — the caller then
    /// falls back to raw stored bytes with NO computation, matching today's
    /// behavior exactly for every unaffected source (the overwhelming
    /// majority). Byte-identity: both the size path and content path MUST
    /// call this with the same inputs and use the SAME returned Data.
    private func rewrittenVerbatimSourceContent(
        id: PageID, mimeType: String?, maps: LinkMaps
    ) -> Data? {
        guard let mime = mimeType, mime.hasPrefix("text/"),
              let siblingMap = maps.siblingImages[id], !siblingMap.isEmpty,
              let store = openReadStore(),
              let raw = try? store.sourceContent(id: id),
              let text = String(data: raw, encoding: .utf8) else { return nil }
        let resolver = maps.imageResolver(forSource: id, baseDir: Self.sourcesByNameDir)
        let rewritten = SourceImageRewriter.rewrite(text, resolver: resolver)
        return Data(rewritten.utf8)
    }

    // MARK: - Enumeration

    /// Children of a container. Opens ONE shared read store for the whole
    /// enumeration pass — the fix for #291 where `children(of: .workingSet)`
    /// opened ~35 independent SQLite connections (one per leaf, per index, per
    /// doc, plus one per `changeToken()` call).
    func children(of container: NSFileProviderItemIdentifier) -> [ProjectedNode] {
        var scoped = self
        scoped.readStoreHolder = ReadScope(databaseURL: databaseURL, wikiID: wikiID)
        return scoped.childrenResolved(of: container)
    }

    /// Store-sharing implementation of `children(of:)`. Called on a scoped copy
    /// carrying a `ReadScope` so every `openReadStore()` / `changeToken()` within
    /// this enumeration reuses one connection (#291).
    private func childrenResolved(of container: NSFileProviderItemIdentifier) -> [ProjectedNode] {
        switch container {
        case .rootContainer:
            var nodes: [ProjectedNode] = []
            // Singleton docs (all aliases, in registry order).
            for doc in Self.singletonDocs {
                for entry in doc.entries {
                    if let n = doc.nodeFor(self, entry.id, entry.name) { nodes.append(n) }
                }
            }
            // Root-level generated indexes (manifest.json).
            for index in Self.generatedIndexes where index.parent == .rootContainer {
                if let n = indexFileNode(for: index) { nodes.append(n) }
            }
            // Flat-resource top-level folders.
            for projection in Self.flatProjections {
                if let n = nodeResolved(for: projection.topLevel) { nodes.append(n) }
            }
            // Nested-resource top-level folders (bookmarks).
            for projection in Self.nestedProjections {
                if let n = nodeResolved(for: projection.topLevel) { nodes.append(n) }
            }
            // The indexes folder.
            if let n = nodeResolved(for: Identity.indexes) { nodes.append(n) }
            return nodes
        case Identity.indexes:
            return Self.generatedIndexes
                .filter { $0.parent == Identity.indexes }
                .compactMap { indexFileNode(for: $0) }
        case .workingSet:
            // The working set is the set of items the daemon actively tracks for
            // change. Re-emit EVERY flat kind's leaves (both views) PLUS the
            // generated index + root-doc nodes so a working-set `enumerateChanges`
            // after a signal carries the new itemVersions and the daemon
            // invalidates its materialized copies (those bytes derive from page +
            // source content, so any mutation must invalidate them). (slice 2b:
            // the flat + doc + index contributions are all registry-driven.)
            var nodes: [ProjectedNode] = []
            for projection in Self.flatProjections {
                nodes += projection.enumerate(self, false)
                nodes += projection.enumerate(self, true)
            }
            // Generated indexes (all — their bytes derive from page/source content).
            for index in Self.generatedIndexes {
                if let n = indexFileNode(for: index) { nodes.append(n) }
            }
            // Singleton docs that participate in the working set (excludes README).
            for doc in Self.singletonDocs where doc.participatesInWorkingSet {
                for entry in doc.entries {
                    if let n = doc.nodeFor(self, entry.id, entry.name) { nodes.append(n) }
                }
            }
            // Nested-resource nodes at all depths (Phase D).
            for projection in Self.nestedProjections {
                nodes += projection.allNodes(self)
            }
            return nodes
        default:
            break
        }
        // Flat-resource containers (slice 2b): a top-level folder yields its two
        // view containers; a view container enumerates its rows (ordered by ULID).
        for projection in Self.flatProjections {
            if container == projection.topLevel {
                return [nodeResolved(for: projection.byIDContainer),
                        nodeResolved(for: projection.byNameContainer)].compactMap { $0 }
            }
            if container == projection.byIDContainer {
                return projection.enumerate(self, false)
            }
            if container == projection.byNameContainer {
                return projection.enumerate(self, true)
            }
        }
        // Nested-resource containers (slice 2b Phase D).
        for projection in Self.nestedProjections {
            if container == projection.topLevel || projection.owns(container) {
                return projection.childrenOf(self, container)
            }
        }
        return []
    }

    /// All page rows projected as file nodes under the given view, ordered by id
    /// (ULID == creation order). For the by-title view, builds a title map once
    /// and computes rewritten content per page so `documentSize` matches the
    /// rewritten bytes that `contents(for:)` will serve.
    private func pageNodes(byTitle: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let pages = try? store.listAllPagesOrderedByID() else { return [] }
        let maps = byTitle ? makeLinkMaps() : nil
        return pages.map { page in
            let id = byTitle ? Identity.pageByTitle(page.id.rawValue)
                             : Identity.pageByID(page.id.rawValue)
            let contentData = maps.map { byTitleContent(for: page, maps: $0) }
            return Self.pageFileNode(for: id, page: page, contentData: contentData)
        }
    }

    /// All ingested-file rows projected as file nodes under the given view,
    /// ordered by id (ULID == ingest order). Resilient to the table not existing
    /// yet (pre-migration) → empty, so enumeration never errors.
    /// When a source has a processed markdown head (from `source_markdown_versions`),
    /// emits BOTH the verbatim source node AND a `.md` sibling — the processed
    /// markdown version — under both `by-id` and `by-name` views. Single bulk
    /// head query avoids N+1 across the source list.
    private func sourceNodes(byName: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let files = try? store.listAllSourcesOrderedByID() else { return [] }
        let heads = (try? store.processedMarkdownHeadsBySource()) ?? [:]
        // Build link maps once for by-name markdown sibling rewriting.
        let maps = byName ? makeLinkMaps() : nil
        return files.flatMap { row in
            let id = byName ? Identity.sourceByName(row.id) : Identity.sourceByID(row.id)
            let summary = SourceSummary(
                id: PageID(rawValue: row.id), filename: row.filename, ext: row.ext,
                mimeType: row.mime, byteSize: row.byteSize,
                createdAt: row.createdAt, updatedAt: row.updatedAt, version: row.version,
                displayName: row.displayName)
            let verbatimContentData = byName
                ? maps.map { rewrittenVerbatimSourceContent(
                    id: PageID(rawValue: row.id), mimeType: row.mime, maps: $0) }
                  .flatMap { $0 }
                : nil
            let verbatimNode = Self.sourceNode(for: id, file: summary, contentData: verbatimContentData)
            // Sibling eligibility: has a chain AND is NOT markdown-native.
            // Markdown-native sources don't get a sibling — the verbatim .md is the content.
            guard let head = heads[row.id],
                  let mime = row.mime, !mime.hasPrefix("text/") else { return [verbatimNode] }
            let markdownID = byName
                ? Identity.sourceMarkdownByName(row.id)
                : Identity.sourceMarkdownByID(row.id)
            let contentData = maps.map {
                rewriteLinks(head.content, maps: $0, baseDir: Self.sourcesByNameDir)
            }
            return [verbatimNode, Self.sourceMarkdownNode(for: markdownID, source: summary,
                                                          head: head, contentData: contentData)]
        }
    }

    /// All chat summaries projected as file nodes under the given view, ordered
    /// by id (ULID == creation order). Mirrors `pageNodes(byTitle:)`. Resilient
    /// to the `chats` table not existing yet (pre-migration) → empty, so
    /// enumeration never errors.
    private func chatNodes(byName: Bool) -> [ProjectedNode] {
        guard let store = openReadStore(),
              let chats = try? store.listAllChatsOrderedByID() else { return [] }
        // Build link maps once for by-name chat rewriting.
        let maps = byName ? makeLinkMaps() : nil
        return chats.map { chat in
            let id = byName ? Identity.chatByName(chat.id.rawValue)
                            : Identity.chatByID(chat.id.rawValue)
            guard let maps else {
                return Self.chatFileNode(for: id, chat: chat, in: store)
            }
            let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
            let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
            let data = rewriteLinks(raw, maps: maps, baseDir: Self.chatsByNameDir)
            return Self.chatFileNode(for: id, chat: chat, in: store, contentData: data)
        }
    }

    /// Build a file node for one chat row, under whichever view `id` belongs to.
    /// Sized from the rendered transcript so `documentSize` matches the bytes
    /// `contents(for:)` serves (else `cat` truncates). Versioned by the chat's
    /// `updated_at` so any message append (which bumps `updated_at`) re-fetches
    /// the node. Like `pageFileNode(for:page:)`.
    static func chatFileNode(for id: NSFileProviderItemIdentifier,
                             chat: ChatSummary,
                             in store: SQLiteWikiStore,
                             contentData: Data? = nil) -> ProjectedNode {
        let raw = id.rawValue
        let isByName = raw.hasPrefix(Identity.chatByNamePrefix)
        let name = isByName
            ? FilenameEscaping.byTitleFilename(title: chat.title, pageID: chat.id.rawValue)
            : FilenameEscaping.byIDFilename(pageID: chat.id.rawValue)
        let parent = isByName ? Identity.chatsByName : Identity.chatsByID
        // Render once for size; `contents(for:)` renders again independently (the
        // read store is cheap + WAL — same pattern as pages). The renderer is
        // deterministic, so the two renders agree byte-for-byte. For by-name,
        // the caller may supply pre-rewritten bytes so size == rewritten content.
        let size: Int
        if let data = contentData {
            size = data.count
        } else {
            let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
            size = ChatTranscriptRenderer.render(summary: chat, messages: messages).utf8.count
        }
        let version = Data(String(chat.updatedAt.timeIntervalSince1970).utf8)
        return .file(
            id: id, parent: parent, name: name, size: size,
            version: version, metadataVersion: version,
            created: chat.createdAt, modified: chat.updatedAt
        )
    }

    // MARK: - Content

    /// Materialize the bytes for a file identifier. README is static; page files
    /// read the live body from SQLite. Folders return nil. Opens ONE shared read
    /// store for the whole resolution (#291).
    func contents(for id: NSFileProviderItemIdentifier) -> Data? {
        var scoped = self
        scoped.readStoreHolder = ReadScope(databaseURL: databaseURL, wikiID: wikiID)
        return scoped.contentsResolved(for: id)
    }

    /// Store-sharing implementation of `contents(for:)`.
    private func contentsResolved(for id: NSFileProviderItemIdentifier) -> Data? {
        // Singleton docs (slice 2b Phase C): dispatch to the matching doc.
        for doc in Self.singletonDocs where doc.entries.contains(where: { $0.id == id }) {
            return doc.contentFor(self)
        }
        // Generated indexes (slice 2b Phase C): serve the SAME token-cached
        // bytes whose length `node(for:)` reported as `documentSize` (else `cat`
        // truncates).
        if Self.generatedIndexes.contains(where: { $0.id == id }) {
            return indexData(for: id)
        }
        // Flat leaf content (slice 2b Phase B): dispatch to the owning
        // flat-resource projection's `contentForLeaf`.
        for projection in Self.flatProjections where projection.owns(id) {
            return projection.contentForLeaf(self, id)
        }
        // Nested leaf content (slice 2b Phase D).
        for projection in Self.nestedProjections where projection.owns(id) {
            return projection.contentFor(self, id)
        }
        return nil
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
    /// Set ONLY for ingested-file leaves: the content-derived MIME type stored in
    /// the `sources` row. `WikiFSItem.contentType` prefers this over `ingestedExt`
    /// when deriving the file's UTType. `nil` for every other node kind.
    let mimeType: String?

    static func folder(id: NSFileProviderItemIdentifier,
                       parent: NSFileProviderItemIdentifier,
                       name: String) -> ProjectedNode {
        ProjectedNode(id: id, parent: parent, name: name, isFolder: true, size: 0,
                      contentVersion: Projection.staticVersion,
                      metadataVersion: Projection.staticVersion,
                      created: nil, modified: nil, ingestedExt: nil, mimeType: nil)
    }

    static func file(id: NSFileProviderItemIdentifier,
                     parent: NSFileProviderItemIdentifier,
                     name: String, size: Int,
                     version: Data, metadataVersion: Data,
                     created: Date?, modified: Date?,
                     ingestedExt: String? = nil,
                     mimeType: String? = nil) -> ProjectedNode {
        ProjectedNode(id: id, parent: parent, name: name, isFolder: false, size: size,
                      contentVersion: version, metadataVersion: metadataVersion,
                      created: created, modified: modified,
                      ingestedExt: ingestedExt, mimeType: mimeType)
    }
}
