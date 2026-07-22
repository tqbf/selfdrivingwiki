import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

/// The daemon's in-process state. Holds the live wiki registry + open stores.
///
/// `GRDBWikiStore` is `@unchecked Sendable` (method-atomic with an internal
/// recursive lock), so it is safe to hold here and serve from XPC handlers.
/// All mutations are serialized on the daemon's dispatch queue for thread safety.
///
/// See `plans/multi-wiki-daemon.md` §4.2.
final class WikiDaemon: @unchecked Sendable {

    // MARK: - Dependencies

    private let containerDirectory: URL
    private let makeStore: (URL) throws -> WikiStore

    // MARK: - State (accessed on `queue`)

    private let queue = DispatchQueue(label: "com.selfdrivingwiki.wikid")
    private var registry: WikiRegistry
    private var openStores: [String: GRDBWikiStore] = [:]

    /// The per-connection event-sink proxies the daemon pushes live workload
    /// events to. Populated by `listener(_:shouldAcceptNewConnection:)` when
    /// the app exports its `WikiDaemonEventSink` conformer on the connection.
    /// Phase 0: captured but not yet pushed to (no real workload dispatch).
    private var eventSinks: [WikiDaemonEventSink] = []

    // MARK: - Workload host scaffold (Phase 0)

    #if canImport(WikiFSEngine)
    /// Lazily-constructed queue engine over the container's `queue.sqlite`.
    /// `nil` until `ensureQueueEngine()` is called. Phase 0: constructed but
    /// not wired to real workers (the stub factory produces no workers).
    /// See `plans/daemon-workloads.md` Phase 0 §3.
    private var _queueEngine: QueueEngine?
    #endif

    /// Whether the daemon can host workloads (macOS + WikiFSEngine linked).
    /// On Linux, this is always `false` — the workload host is compiled out.
    var canHostWorkloads: Bool {
        #if canImport(WikiFSEngine)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Init

    /// Inject `containerDirectory` + `makeStore` for testability.
    init(
        containerDirectory: URL,
        makeStore: @escaping (URL) throws -> WikiStore = { try GRDBWikiStore(databaseURL: $0) }
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
                let store = try makeStore(dbURL) as? GRDBWikiStore
                openStores[descriptor.id] = store
            } catch {
                DebugLog.store("wikid: createWiki failed for \(descriptor.id): \(error)")
                return nil
            }

            // Seed a Home page if the store is empty (mirrors WikiRegistryClient.createWiki)
            if let store = openStores[descriptor.id] {
                let pages = (try? store.listPages(sortBy: .newestFirst)) ?? []
                if pages.isEmpty {
                    // #797: pre-fix `createdBy: nil` mapped to the shared
                    // `legacy-import` agent, so the daemon-seeded Home page
                    // read as `legacy-import` in `pageOrigin` / the Provenance
                    // panel. A daemon bootstrap is an explicit (synthesized)
                    // user action — stamp `user`.
                    if let homePage = try? store.createPage(
                        title: "Home",
                        createdBy: PageAuthor.user.rawValue) {
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
                let store = try GRDBWikiStore(databaseURL: dbURL)
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
            _ = openStores.removeValue(forKey: wikiID)
        }
    }

    /// Sentinel returned by ``changeToken(wikiID:)`` when reading the store's
    /// change token throws. A genuine change token is always colon-joined
    /// integers (e.g. `"0:0:0:…"`), so this is syntactically distinguishable
    /// from a real "no changes" token — and it never matches a previously
    /// cached anchor, so callers (the File Provider enumerator) treat it as
    /// "changed" and re-sync rather than silently skipping an update (#487).
    /// Contrast with `""`, which means the wikiID is unknown (not registered).
    static let errorTokenSentinel = "<<changeToken-read-error>>"

    func changeToken(wikiID: String) -> String {
        queue.sync { () -> String in
            // If the store is open, read the token directly.
            // Never swallow a thrown error as `""` (which would be reported to
            // the File Provider as "no changes" → stale projections, #487).
            if let store = openStores[wikiID] {
                do {
                    return try store.changeToken().rawString
                } catch {
                    DebugLog.store("wikid: changeToken() failed for \(wikiID) (open store): \(error)")
                    return Self.errorTokenSentinel
                }
            }
            // Store not held open — open it transiently to read the token.
            // Unknown wiki → "" (genuine "not registered"); any thrown error
            // during open/read → sentinel (logs + forces caller re-sync).
            guard registry.descriptor(id: wikiID) != nil else { return "" }
            let dbURL = databaseURL(forWikiID: wikiID)
            let store: GRDBWikiStore
            do {
                store = try GRDBWikiStore(databaseURL: dbURL)
            } catch {
                DebugLog.store("wikid: changeToken() failed to open transient store for \(wikiID): \(error)")
                return Self.errorTokenSentinel
            }
            do {
                return try store.changeToken().rawString
            } catch {
                DebugLog.store("wikid: changeToken() failed for \(wikiID) (transient store): \(error)")
                return Self.errorTokenSentinel
            }
        }
    }

    // MARK: - Internal

    private func databaseURL(forWikiID id: String) -> URL {
        containerDirectory.appendingPathComponent("\(id).sqlite", isDirectory: false)
    }

    // MARK: - Event sink management (Phase 0)

    /// Register an event-sink proxy for a connection. The daemon holds it weakly
    /// (the proxy is retained by the `NSXPCConnection`). Called from
    /// `WikiDaemonExporter.registerEventSink`.
    func registerEventSink(_ sink: WikiDaemonEventSink) {
        queue.sync {
            eventSinks.append(sink)
        }
    }

    /// All currently-registered event-sink proxies. Used by future phases to
    /// push live workload events; Phase 0 exposes it for testing.
    var registeredEventSinks: [WikiDaemonEventSink] {
        queue.sync { eventSinks }
    }

    // MARK: - Workload host (Phase 0 — scaffold)

    /// The `queue.sqlite` URL inside the container directory.
    private var queueDatabaseURL: URL {
        containerDirectory.appendingPathComponent("queue.sqlite", isDirectory: false)
    }

    #if canImport(WikiFSEngine)
    /// Construct (or return the existing) `QueueEngine` over the container's
    /// `queue.sqlite`. The engine is constructed with a **stub worker factory**
    /// that never produces workers — Phase 0 demonstrates the daemon CAN host
    /// the engine; Phase A wires real extraction workers, Phase B ingestion.
    ///
    /// Thread-safe: synchronized on `queue`. The engine itself is a `Sendable`
    /// actor, so once constructed it is safe to serve from XPC handlers.
    func ensureQueueEngine() throws -> QueueEngine {
        try queue.sync {
            if let engine = _queueEngine {
                return engine
            }
            let store = try QueueStore(databaseURL: queueDatabaseURL)
            let engine = QueueEngine(
                store: store,
                config: QueueEngineConfig(),
                workerFactory: DaemonStubWorkerFactory()
            )
            _queueEngine = engine
            return engine
        }
    }

    /// Serve a queue snapshot as JSON `Data` for the XPC `queueSnapshot` method.
    /// The engine's `snapshot()` is async (it's an actor method), so this is
    /// async too — the exporter wraps it in a `Task` and replies when it
    /// resolves. In Phase 0 the stub factory never dispatches workers, so the
    /// snapshot contains only items the app enqueues (none yet).
    func queueSnapshotData() async -> Data {
        guard let engine = try? ensureQueueEngine() else {
            return (try? JSONEncoder().encode(QueueSnapshot())) ?? Data()
        }
        let snapshot = await engine.snapshot()
        return (try? JSONEncoder().encode(snapshot)) ?? Data()
    }
    #else
    /// On Linux (no WikiFSEngine), returns an empty JSON snapshot.
    func queueSnapshotData() async -> Data {
        Data()
    }
    #endif
}

#if canImport(WikiFSEngine)
/// A no-op `QueueWorkerFactory` used by the daemon's workload host in Phase 0.
/// `providerID(for:)` always returns `nil`, so the `QueueEngine`'s dispatch
/// scan never claims an item — enqueued items sit in `.queued` indefinitely.
/// This is intentional: Phase 0 demonstrates the daemon CAN construct and host
/// a `QueueEngine`; Phase A replaces this with a real extraction factory.
///
/// See `plans/daemon-workloads.md` Phase 0 §3.
private struct DaemonStubWorkerFactory: QueueWorkerFactory {
    func providerID(for item: QueueItem) async -> String? { nil }
    func worker(for item: QueueItem) async throws -> any QueueWorker {
        throw QueueIngestionError.noSources
    }
}
#endif
