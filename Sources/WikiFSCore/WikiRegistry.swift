import Foundation

/// The set of wikis a user keeps — the multi-wiki foundation (`plans/llm-wiki.md`
/// Phase 0). Persisted as a tiny `wikis.json` in the App Group container, read by
/// the app to populate the switcher and to register one File Provider domain per
/// wiki on launch.
///
/// This is a plain value type with explicit load/save against an injected
/// directory, so it is pure and unit-testable (tests point it at a temp dir; the
/// app points it at the App Group container). All identity is the wiki's ULID,
/// never its display name (rename-safe, per the doc's open-risk).
public struct WikiRegistry: Codable, Equatable, Sendable {
    /// All wikis, most-recently-used FIRST (the order the switcher shows and the
    /// app picks the active wiki from on launch).
    public private(set) var wikis: [WikiDescriptor]

    public init(wikis: [WikiDescriptor] = []) {
        self.wikis = wikis
    }

    /// The registry's JSON filename inside the App Group container.
    public static let fileName = "wikis.json"

    // MARK: - Queries

    public var isEmpty: Bool { wikis.isEmpty }

    public func descriptor(id: String) -> WikiDescriptor? {
        wikis.first { $0.id == id }
    }

    /// The wiki the app should open: the most-recently-used (first, since the
    /// list is MRU-ordered). `nil` only when the registry is empty.
    public var mostRecentlyUsed: WikiDescriptor? { wikis.first }

    // MARK: - Mutations (in-memory; caller persists via `save`)

    /// Add a freshly-minted wiki at the FRONT (it becomes most-recently-used).
    public mutating func add(_ descriptor: WikiDescriptor) {
        wikis.removeAll { $0.id == descriptor.id }
        wikis.insert(descriptor, at: 0)
    }

    /// Rename a wiki — changes ONLY the display name (identity, DB filename, and
    /// domain identifier are the ULID, untouched). No-op if the id is unknown.
    public mutating func rename(id: String, to displayName: String) {
        guard let index = wikis.firstIndex(where: { $0.id == id }) else { return }
        wikis[index].displayName = displayName
    }

    /// Set (or clear, with `nil`) a wiki's home page. No-op if the id is unknown.
    public mutating func setHomePage(id: String, pageID: PageID?) {
        guard let index = wikis.firstIndex(where: { $0.id == id }) else { return }
        wikis[index].homePageID = pageID
    }

    /// Mark a wiki as just-used: bump `lastUsedAt` and move it to the front so MRU
    /// ordering (and the launch pick) stays correct.
    public mutating func touch(id: String, now: Date = Date()) {
        guard let index = wikis.firstIndex(where: { $0.id == id }) else { return }
        wikis[index].lastUsedAt = now
        let descriptor = wikis.remove(at: index)
        wikis.insert(descriptor, at: 0)
    }

    /// Remove a wiki from the registry (the caller separately drops its DB files
    /// and File Provider domain). No-op if the id is unknown.
    public mutating func remove(id: String) {
        wikis.removeAll { $0.id == id }
    }

    // MARK: - Persistence

    /// Load the registry from `wikis.json` in `directory`. A missing file means a
    /// fresh install → an empty registry (NOT an error). A corrupt file also
    /// degrades to empty rather than crashing the app on launch.
    public static func load(from directory: URL) -> WikiRegistry {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return WikiRegistry() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let registry = try? decoder.decode(WikiRegistry.self, from: data) else {
            DebugLog.config("WikiRegistry: corrupt \(fileName), starting empty")
            return WikiRegistry()
        }
        return registry
    }

    /// Persist the registry to `wikis.json` in `directory` (pretty-printed +
    /// sorted keys so diffs are reviewable; ISO-8601 dates to match `load`).
    /// Written atomically so a crash mid-write can't truncate it.
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(WikiRegistry.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
