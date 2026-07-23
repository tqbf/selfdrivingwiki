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
    /// macOS-only — `WikiDaemonEventSink` is an `@objc` XPC protocol.
    #if os(macOS)
    private var eventSinks: [WikiDaemonEventSink] = []
    #endif

    // MARK: - Workload host scaffold (Phase 0)

    #if canImport(WikiFSEngine)
    /// Lazily-constructed queue engine over the container's `queue.sqlite`.
    /// `nil` until `ensureQueueEngine()` is called. Wired to real extraction +
    /// ingestion worker factories that talk to `GRDBWikiStore` directly.
    /// See `plans/daemon-workloads.md`.
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
                if let store {
                    wireEventBus(on: store, wikiID: descriptor.id)
                    cacheStore(store, wikiID: descriptor.id)
                } else {
                    openStores[descriptor.id] = nil
                }
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
                wireEventBus(on: store, wikiID: wikiID)
                cacheStore(store, wikiID: wikiID)
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

    /// Lazily resolve (and cache) the `GRDBWikiStore` for `wikiID`.
    ///
    /// Backs the queue-engine and chat-host `storeResolver` closures so a
    /// workload for a wiki the daemon hasn't explicitly opened still resolves:
    /// if the store isn't already cached in `openStores` but the wiki is
    /// registered, open it read-write (running the bootstrap ladder on first
    /// open) and cache it. Returns `nil` for an unregistered wikiID or if the
    /// open throws. Same lazy-open pattern as `openStore(wikiID:)`, but returns
    /// the store instead of a `Bool` (#867).
    func resolveStoreLazily(wikiID: String) -> GRDBWikiStore? {
        queue.sync { () -> GRDBWikiStore? in
            if let store = openStores[wikiID] {
                return store
            }
            guard registry.descriptor(id: wikiID) != nil else { return nil }
            let dbURL = databaseURL(forWikiID: wikiID)
            do {
                let store = try GRDBWikiStore(databaseURL: dbURL)
                wireEventBus(on: store, wikiID: wikiID)
                cacheStore(store, wikiID: wikiID)
                DebugLog.store("wikid: store lazily opened for \(wikiID)")
                return store
            } catch {
                DebugLog.store("wikid: lazy openStore failed for \(wikiID): \(error)")
                return nil
            }
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

    /// Attach a per-wiki `WikiEventBus` to `store` whose all-events listener
    /// forwards every committed mutation to a Darwin change notification.
    ///
    /// The daemon's stores live in a separate process from the app, so the
    /// store's own `ResourceChangeEvent` emissions (from `mutate()`) can't
    /// reach the app directly. This wiring bridges them: each event →
    /// `DarwinNotifier.postChange(forWikiID:)` → the app's `WikiChangeBridge`
    /// receives the cross-process Darwin notification → coalesces → reloads.
    ///
    /// Without it, daemon-only writes that never pass through an agent
    /// `onUnlock` callback (summarizer writes, queue-extraction completion,
    /// chat-message appends) emit into a nil bus and the app never learns about
    /// them (#871 follow-up): persisted chat summaries stayed invisible and
    /// completed queue items never refreshed the Activity window. Idempotent —
    /// a no-op if the store already carries a bus.
    ///
    /// `eventBus` stays optional on `GRDBWikiStore` itself because `wikictl`
    /// and the File Provider's read-only open intentionally run busless. The
    /// daemon, however, treats a busless store as a programming error: the
    /// trailing `assert` is the **mandatory-bus invariant** — it fires in debug
    /// builds if wiring was skipped or the assignment didn't stick.
    private func wireEventBus(on store: GRDBWikiStore, wikiID: String) {
        if store.eventBus == nil {
            let bus = WikiEventBus(wikiID: wikiID)
            bus.subscribe(nil) { event in
                DarwinNotifier.postChange(forWikiID: event.wikiID)
            }
            store.eventBus = bus
        }
        assert(
            store.eventBus != nil,
            "Daemon store must have a WikiEventBus attached — DarwinNotifier will never fire without it")
    }

    /// Cache `store` under `wikiID` in `openStores`. The **sole sanctioned
    /// insertion point** — enforces the daemon invariant that every held store
    /// carries a change bus (#871 follow-up), so a future store-creation path
    /// that forgets to call `wireEventBus` still trips the assert the moment it
    /// tries to cache the store. Removals (`closeStore`/`deleteWiki`) bypass
    /// this. Do NOT assign `openStores[...] = ...` directly elsewhere.
    @discardableResult
    private func cacheStore(_ store: GRDBWikiStore, wikiID: String) -> GRDBWikiStore {
        assert(
            store.eventBus != nil,
            "Daemon store must have a WikiEventBus attached — DarwinNotifier will never fire without it")
        openStores[wikiID] = store
        return store
    }

    // MARK: - Event sink management (Phase 0)

    /// Register an event-sink proxy for a connection. The daemon holds it weakly
    /// (the proxy is retained by the `NSXPCConnection`). Called from
    /// `WikiDaemonExporter.registerEventSink`.
    #if os(macOS)
    func registerEventSink(_ sink: WikiDaemonEventSink) {
        let total = queue.sync { () -> Int in
            eventSinks.append(sink)
            return eventSinks.count
        }
        DebugLog.store("wikid: event sink registered, total=\(total)")
    }

    /// All currently-registered event-sink proxies. Used by future phases to
    /// push live workload events; Phase 0 exposes it for testing.
    var registeredEventSinks: [WikiDaemonEventSink] {
        queue.sync { eventSinks }
    }
    #endif

    // MARK: - Workload host (Phase 0 — scaffold)

    /// The `queue.sqlite` URL inside the container directory.
    private var queueDatabaseURL: URL {
        containerDirectory.appendingPathComponent("queue.sqlite", isDirectory: false)
    }

    #if canImport(WikiFSEngine)
    /// Construct (or return the existing) `QueueEngine` over the container's
    /// `queue.sqlite`. The engine is wired with real extraction + ingestion
    /// worker factories backed by `GRDBWikiStore`.
    ///
    /// Async because constructing the `ExtractionCoordinator` (`@MainActor`)
    /// requires a main-actor hop. Thread-safe: double-checked on `queue`.
    func ensureQueueEngine() async throws -> QueueEngine {
        if let engine = queue.sync(execute: { _queueEngine }) {
            return engine
        }

        let coordinator = await MainActor.run {
            ExtractionCoordinator(
                containerDirectory: containerDirectory,
                localExtractorFactory: { LocalPdf2MarkdownExtractor() })
        }

        let storeResolver: @Sendable (String) -> GRDBWikiStore? = { [weak self] wikiID in
            self?.resolveStoreLazily(wikiID: wikiID)
        }

        let queueStore = try QueueStore(databaseURL: queueDatabaseURL)

        let extractionProvider = DaemonQueueExtractionProvider(
            containerDirectory: containerDirectory,
            extractionCoordinator: coordinator,
            storeResolver: storeResolver)

        let dir = containerDirectory
        let ingestionProvider = DaemonQueueIngestionProvider(
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            storeResolver: storeResolver,
            queueStore: queueStore,
            resolveSelectedProvider: {
                AgentProvidersConfig.loadOrSeed(from: dir).selectedProvider()
            },
            resolveProviderConfig: {
                AgentProvidersConfig.loadOrSeed(from: dir)
            })

        let progressBox = DaemonEmitBox<(@Sendable (QueueItem.ID, String) -> Void)>()
        let transcriptBox = DaemonEmitBox<(@Sendable (QueueItem.ID, AgentEvent) -> Void)>()
        let usageBox = DaemonEmitBox<(@Sendable (QueueItem.ID, SessionUsage) -> Void)>()
        let liveUsageBox = DaemonEmitBox<(@Sendable (QueueItem.ID, SessionUsage) -> Void)>()
        let logPathsBox = DaemonEmitBox<(@Sendable (QueueItem.ID, URL?, URL?) -> Void)>()
        let pendingPermissionBox = DaemonEmitBox<(@Sendable (QueueItem.ID, PendingPermission?) -> Void)>()

        let extractionFactory = QueueExtractionWorkerFactory(
            provider: extractionProvider,
            emitProgress: { id, line in progressBox.emit?(id, line) })

        let ingestionFactory = QueueIngestionWorkerFactory(
            provider: ingestionProvider,
            emitProgress: { id, line in progressBox.emit?(id, line) },
            emitTranscript: { id, event in transcriptBox.emit?(id, event) },
            emitUsage: { id, usage in usageBox.emit?(id, usage) },
            emitLiveUsage: { id, usage in liveUsageBox.emit?(id, usage) },
            emitLogPaths: { id, logURL, debugURL in logPathsBox.emit?(id, logURL, debugURL) },
            emitPendingPermission: { id, permission in pendingPermissionBox.emit?(id, permission) })

        let workerFactory = CompositeWorkerFactory(factories: [
            .extraction: extractionFactory,
            .ingestion: ingestionFactory,
        ])

        let engine = QueueEngine(store: queueStore, workerFactory: workerFactory)

        Task { progressBox.emit = await engine.makeEmitProgress() }
        Task { transcriptBox.emit = await engine.makeEmitTranscript() }
        Task { usageBox.emit = await engine.makeEmitUsage() }
        Task { liveUsageBox.emit = await engine.makeEmitLiveUsage() }
        Task { logPathsBox.emit = await engine.makeEmitLogPaths() }
        Task { pendingPermissionBox.emit = await engine.makeEmitPendingPermission() }

        let engineRef = engine
        Task { [weak self] in
            for await event in engineRef.events {
                self?.pushQueueEvent(event)
            }
        }

        Task { await engine.start() }

        return queue.sync {
            if let existing = _queueEngine {
                return existing
            }
            _queueEngine = engine
            return engine
        }
    }

    /// Serve a queue snapshot as JSON `Data` for the XPC `queueSnapshot` method.
    /// The engine's `snapshot()` is async (it's an actor method), so this is
    /// async too — the exporter wraps it in a `Task` and replies when it
    /// resolves.
    func queueSnapshotData() async -> Data {
        guard let engine = try? await ensureQueueEngine() else {
            return (try? JSONEncoder().encode(QueueSnapshot())) ?? Data()
        }
        let snapshot = await engine.snapshot()
        return (try? JSONEncoder().encode(snapshot)) ?? Data()
    }

    // MARK: - Chat host (Phase C)

    #if canImport(WikiFSEngine)
    /// Lazily-constructed chat host owning the live `[chatID → ChatSession]`
    /// registry. `nil` until `ensureChatHost()` is called.
    private var _chatHost: DaemonChatHost?

    /// Construct (or return the existing) `DaemonChatHost`. The host is wired
    /// with the same `storeResolver` + container the queue engine uses, so chat
    /// persistence lands on the same `GRDBWikiStore` instances.
    func ensureChatHost() async throws -> DaemonChatHost {
        if let host = queue.sync(execute: { _chatHost }) {
            return host
        }

        let coordinator = await MainActor.run {
            ExtractionCoordinator(
                containerDirectory: containerDirectory,
                localExtractorFactory: { LocalPdf2MarkdownExtractor() })
        }

        let storeResolver: @Sendable (String) -> GRDBWikiStore? = { [weak self] wikiID in
            self?.resolveStoreLazily(wikiID: wikiID)
        }

        let dir = containerDirectory
        let host = DaemonChatHost(
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            storeResolver: storeResolver,
            resolveSelectedProvider: {
                AgentProvidersConfig.loadOrSeed(from: dir).selectedProvider()
            },
            resolveProviderConfig: {
                AgentProvidersConfig.loadOrSeed(from: dir)
            },
            pushEvent: { [weak self] envelope in
                self?.pushChatEnvelope(envelope)
            })

        return queue.sync {
            if let existing = _chatHost {
                return existing
            }
            _chatHost = host
            return host
        }
    }
    #endif

    /// Start a chat. Returns JSON `ChatStartReply`. Async because the chat
    /// host constructs an `AgentLauncher` on the main actor.
    func startChatData(request: Data) async -> Data {
        #if canImport(WikiFSEngine)
        do {
            let host = try await ensureChatHost()
            let req = try JSONDecoder().decode(ChatStartRequest.self, from: request)
            let chatID = try await host.startChat(wikiID: req.wikiID, firstMessage: req.firstMessage)
            let reply = ChatStartReply(chatID: chatID, error: nil)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        } catch {
            let reply = ChatStartReply(chatID: nil, error: error.localizedDescription)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        }
        #else
        return Data()
        #endif
    }

    /// Continue a chat. Returns JSON `ChatErrorReply`.
    func continueChatData(request: Data) async -> Data {
        #if canImport(WikiFSEngine)
        do {
            let host = try await ensureChatHost()
            let req = try JSONDecoder().decode(ChatContinueRequest.self, from: request)
            try await host.continueChat(wikiID: req.wikiID, chatID: req.chatID, message: req.message)
            let reply = ChatErrorReply(error: nil)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        } catch {
            let reply = ChatErrorReply(error: error.localizedDescription)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        }
        #else
        return Data()
        #endif
    }

    /// Send a follow-up turn. Returns JSON `ChatErrorReply`.
    func sendChatMessageData(request: Data) async -> Data {
        #if canImport(WikiFSEngine)
        do {
            let host = try await ensureChatHost()
            guard let dict = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let chatID = dict["chatID"] as? String,
                  let message = dict["message"] as? String else {
                let reply = ChatErrorReply(error: "invalid request")
                return (try? JSONEncoder().encode(reply)) ?? Data()
            }
            try await host.sendChatMessage(chatID: chatID, message: message)
            let reply = ChatErrorReply(error: nil)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        } catch {
            let reply = ChatErrorReply(error: error.localizedDescription)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        }
        #else
        return Data()
        #endif
    }

    /// Stop a chat.
    func stopChat(chatID: String) async {
        #if canImport(WikiFSEngine)
        if let host = try? await ensureChatHost() {
            await host.stopChat(chatID: chatID)
        }
        #endif
    }

    /// Get the chat session state. Returns JSON `ChatSessionState`.
    func chatSessionStateData(chatID: String) async -> Data {
        #if canImport(WikiFSEngine)
        do {
            let host = try await ensureChatHost()
            let state = try await host.chatSessionState(chatID: chatID)
            return (try? JSONEncoder().encode(state)) ?? Data()
        } catch {
            return Data()
        }
        #else
        return Data()
        #endif
    }

    /// Resolve a chat permission.
    func resolveChatPermissionData(request: Data) async {
        #if canImport(WikiFSEngine)
        if let host = try? await ensureChatHost(),
           let req = try? JSONDecoder().decode(ChatPermissionResolveRequest.self, from: request) {
            await host.resolvePermission(
                chatID: req.chatID, optionId: req.optionId, approve: req.approve)
        }
        #endif
    }

    /// Set a chat config option. Returns JSON `ChatErrorReply`.
    func setChatConfigOptionData(request: Data) async -> Data {
        #if canImport(WikiFSEngine)
        do {
            let host = try await ensureChatHost()
            let req = try JSONDecoder().decode(ChatConfigOptionRequest.self, from: request)
            try await host.setChatConfigOption(
                chatID: req.chatID, option: req.option, value: req.value)
            let reply = ChatErrorReply(error: nil)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        } catch {
            let reply = ChatErrorReply(error: error.localizedDescription)
            return (try? JSONEncoder().encode(reply)) ?? Data()
        }
        #else
        return Data()
        #endif
    }
    #else
    /// On Linux (no WikiFSEngine), returns an empty JSON snapshot.
    func queueSnapshotData() async -> Data {
        Data()
    }
    #endif

    // MARK: - Event forwarding

    #if os(macOS)
    /// Encode a `QueueEvent` as a `QueueEventEnvelope`, JSON-encode it to
    /// `Data`, and call `deliverEvent` on all registered event sinks. This is
    /// the sole path by which engine events reach the app over XPC.
    func pushQueueEvent(_ event: QueueEvent) {
        #if canImport(WikiFSEngine)
        guard let envelope = QueueEventEnvelope(from: event) else {
            DebugLog.store("wikid: pushQueueEvent — failed to create envelope")
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            DebugLog.store("wikid: pushQueueEvent — JSON encode failed for kind=\(envelope.kind.rawValue): \(error)")
            return
        }
        let sinks = queue.sync { eventSinks }
        DebugLog.store("wikid: pushQueueEvent kind=\(envelope.kind.rawValue) sinks=\(sinks.count)")
        for sink in sinks {
            sink.deliverEvent(data)
        }
        #endif
    }

    /// Encode a chat `QueueEventEnvelope` to `Data` and call `deliverEvent`
    /// on all registered event sinks. The sole path by which chat events
    /// reach the app over XPC.
    func pushChatEnvelope(_ envelope: QueueEventEnvelope) {
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            DebugLog.store("wikid: pushChatEnvelope — JSON encode failed for kind=\(envelope.kind.rawValue): \(error)")
            return
        }
        let sinks = queue.sync { eventSinks }
        DebugLog.store("wikid: pushChatEnvelope kind=\(envelope.kind.rawValue) chatID=\(envelope.chatID ?? "nil") sinks=\(sinks.count)")
        for sink in sinks {
            sink.deliverEvent(data)
        }
    }
    #endif
}

#if canImport(WikiFSEngine)
/// A mutable box for a `@Sendable` emit closure. Used to break the circular
/// dependency between the worker factories (need the closure) and the engine
/// (provides it). Generic over the closure type so all six emit boxes share
/// one implementation.
final class DaemonEmitBox<T>: @unchecked Sendable {
    var emit: T?
}
#endif
