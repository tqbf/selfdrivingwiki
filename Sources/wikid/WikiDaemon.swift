import Foundation
import WikiFSCore

/// The daemon's in-process state. Holds the live wiki registry + open stores.
///
/// `SQLiteWikiStore` is `@unchecked Sendable` (method-atomic with an internal
/// recursive lock), so it is safe to hold here and serve from XPC handlers.
/// All mutations are serialized on the daemon's dispatch queue for thread safety.
///
/// See `plans/multi-wiki-daemon.md` §4.2.
final class WikiDaemon {

    // MARK: - Dependencies

    private let containerDirectory: URL
    private let makeStore: (URL) throws -> WikiStore

    // MARK: - State (accessed on `queue`)

    private let queue = DispatchQueue(label: "com.selfdrivingwiki.wikid")
    private var registry: WikiRegistry
    private var openStores: [String: SQLiteWikiStore] = [:]

    // MARK: - Init

    /// Inject `containerDirectory` + `makeStore` for testability.
    init(
        containerDirectory: URL,
        makeStore: @escaping (URL) throws -> WikiStore = { try SQLiteWikiStore(databaseURL: $0) }
    ) {
        self.containerDirectory = containerDirectory
        self.makeStore = makeStore
        self.registry = WikiRegistry.load(from: containerDirectory)
    }

    // MARK: - Registry

    func listWikis() -> Data {
        queue.sync {
            (try? JSONEncoder().encode(registry.wikis)) ?? Data()
        }
    }

    func createWiki(name: String) -> Data? {
        queue.sync { () -> Data? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmed.isEmpty ? "Untitled Wiki" : trimmed
            let descriptor = WikiDescriptor.make(displayName: displayName)

            // Open + seed the DB (runs the bootstrap ladder — pages, system prompt, search tables)
            let dbURL = databaseURL(forWikiID: descriptor.id)
            do {
                let store = try makeStore(dbURL) as? SQLiteWikiStore
                openStores[descriptor.id] = store
            } catch {
                DebugLog.store("wikid: createWiki failed for \(descriptor.id): \(error)")
                return nil
            }

            // Seed a Home page if the store is empty (mirrors WikiRegistryClient.createWiki)
            if let store = openStores[descriptor.id] {
                let pages = (try? store.listPages(sortBy: .newestFirst)) ?? []
                if pages.isEmpty {
                    if let homePage = try? store.createPage(title: "Home", createdBy: nil) {
                        var desc = descriptor
                        desc.homePageID = homePage.id
                        registry.add(desc)
                    } else {
                        registry.add(descriptor)
                    }
                } else {
                    registry.add(descriptor)
                }
            } else {
                registry.add(descriptor)
            }

            try? registry.save(to: containerDirectory)
            return try? JSONEncoder().encode(registry.descriptor(id: descriptor.id) ?? descriptor)
        }
    }

    func deleteWiki(id: String) -> Bool {
        queue.sync { () -> Bool in
            // Close the held store if open
            openStores.removeValue(forKey: id)

            // Remove from registry
            registry.remove(id: id)
            try? registry.save(to: containerDirectory)

            // Delete DB files (main + WAL sidecars)
            let dbURL = databaseURL(forWikiID: id)
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let path = dbURL.path + suffix
                try? fm.removeItem(atPath: path)
            }
            return true
        }
    }

    func renameWiki(id: String, name: String) -> Bool {
        queue.sync { () -> Bool in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard registry.descriptor(id: id) != nil else { return false }
            registry.rename(id: id, to: trimmed)
            try? registry.save(to: containerDirectory)
            return true
        }
    }

    func resolveWiki(selector: String) -> Data? {
        queue.sync {
            // Mirrors WikiResolver.descriptor(forSelector:): ULID first, then displayName
            let descriptor = registry.descriptor(id: selector)
                ?? registry.wikis.first { $0.displayName == selector }
            return descriptor.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    // MARK: - Store lifecycle

    func openStore(wikiID: String) -> Bool {
        queue.sync { () -> Bool in
            // Already open — no-op
            if openStores[wikiID] != nil { return true }

            guard registry.descriptor(id: wikiID) != nil else { return false }
            let dbURL = databaseURL(forWikiID: wikiID)
            do {
                // Read-write open (runs bootstrap ladder on first open)
                let store = try SQLiteWikiStore(databaseURL: dbURL)
                openStores[wikiID] = store
                return true
            } catch {
                DebugLog.store("wikid: openStore failed for \(wikiID): \(error)")
                return false
            }
        }
    }

    func closeStore(wikiID: String) {
        queue.sync {
            // Best-effort: remove from the held-open dict. The store is deinit'd by ARC.
            // If another client had a session, it will re-open on next use.
            openStores.removeValue(forKey: wikiID)
        }
    }

    func changeToken(wikiID: String) -> String {
        queue.sync { () -> String in
            // If the store is open, read the token directly
            if let store = openStores[wikiID] {
                return (try? store.changeToken()) ?? ""
            }
            // Store not held open — open it transiently to read the token
            guard registry.descriptor(id: wikiID) != nil else { return "" }
            let dbURL = databaseURL(forWikiID: wikiID)
            guard let store = try? SQLiteWikiStore(databaseURL: dbURL) else { return "" }
            return (try? store.changeToken()) ?? ""
        }
    }

    // MARK: - Internal

    private func databaseURL(forWikiID id: String) -> URL {
        containerDirectory.appendingPathComponent("\(id).sqlite", isDirectory: false)
    }
}
