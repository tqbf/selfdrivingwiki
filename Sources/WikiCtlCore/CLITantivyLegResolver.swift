import Foundation
import WikiFSCore

#if os(macOS)
import Cordis
import CordisLoader
import WikiFSEngine

public enum CLIStoreProfileError: Error {
    case incompatibleStore
    case operationAndCleanup(operation: any Error, cleanup: any Error)
}

public struct CLIStoreProfile: Sendable {
    public struct Request: Sendable {
        public let databaseURL: URL
        public let wikiID: WikiID
        public let containerDirectory: URL

        public init(databaseURL: URL, wikiID: WikiID, containerDirectory: URL) {
            self.databaseURL = databaseURL
            self.wikiID = wikiID
            self.containerDirectory = containerDirectory
        }
    }

    public typealias Boot = @Sendable (Request) async throws -> BootedProfile

    private let boot: Boot

    public init() {
        self.boot = CLIStoreProfile.productionBoot
    }

    public init(boot: @escaping Boot) {
        self.boot = boot
    }

    public func withStore<Result>(
        request: Request,
        operation: (GRDBWikiStore) async throws -> Result
    ) async throws -> Result {
        let profile = try await boot(request)
        let operationResult: Swift.Result<Result, any Error>
        do {
            let service = try await profile.context.require(StoreServiceKeys.store)
            guard let store = service as? GRDBWikiStore else {
                throw CLIStoreProfileError.incompatibleStore
            }
            operationResult = .success(try await operation(store))
        } catch {
            operationResult = .failure(error)
        }

        do {
            try await profile.shutdown()
        } catch {
            switch operationResult {
            case .success:
                throw error
            case .failure(let operationError):
                throw CLIStoreProfileError.operationAndCleanup(
                    operation: operationError,
                    cleanup: error)
            }
        }

        return try operationResult.get()
    }

    public static func withStore<Result>(
        databaseURL: URL,
        wikiID: WikiID,
        containerDirectory: URL,
        operation: (GRDBWikiStore) async throws -> Result
    ) async throws -> Result {
        try await CLIStoreProfile().withStore(
            request: Request(
                databaseURL: databaseURL,
                wikiID: wikiID,
                containerDirectory: containerDirectory),
            operation: operation)
    }

    private static func productionBoot(_ request: Request) async throws -> BootedProfile {
        try await CordisBoot.boot(.init(
            catalog: try CLIPluginCatalog.build(),
            layers: [PatchFile(entries: try ProductionProfiles.cli(
                databaseURL: request.databaseURL,
                wikiID: request.wikiID,
                homeDirectory: request.containerDirectory))]))
    }

}

public struct WikiCtlRunner {
    public struct Output: Sendable, Equatable {
        public let stdout: Data
        public let stderr: Data
        public let changedWikiID: WikiID?

        public init(stdout: Data = Data(), stderr: Data = Data(), changedWikiID: WikiID? = nil) {
            self.stdout = stdout
            self.stderr = stderr
            self.changedWikiID = changedWikiID
        }
    }

    public typealias CommandExecutor = (
        ArgumentParser.Command,
        GRDBWikiStore,
        WikiID,
        URL
    ) async throws -> SourceCommand.Result

    private let resolveContainer: () throws -> WikiResolver
    private let storeProfile: CLIStoreProfile
    private let bootstrap: StoreBootstrap
    private let execute: CommandExecutor

    public init(
        resolveContainer: @escaping () throws -> WikiResolver = WikiResolver.appGroupContainer,
        storeProfile: CLIStoreProfile = CLIStoreProfile(),
        bootstrap: StoreBootstrap = StoreBootstrap(),
        execute: @escaping CommandExecutor
    ) {
        self.resolveContainer = resolveContainer
        self.storeProfile = storeProfile
        self.bootstrap = bootstrap
        self.execute = execute
    }

    public func runOrdinary(
        command: ArgumentParser.Command,
        wikiSelector: String,
        environment: [String: String]
    ) async throws -> Output {
        let resolvedCommand = ArgumentParser.applyEnv(command, env: environment)
        let resolver = try resolveContainer()
        guard let descriptor = resolver.descriptor(forSelector: wikiSelector) else {
            throw PageCommand.Failure.message(
                "no wiki matching \(wikiSelector.debugDescription) in the registry")
        }
        let result = try await storeProfile.withStore(request: CLIStoreProfile.Request(
            databaseURL: resolver.databaseURL(for: descriptor),
            wikiID: descriptor.id,
            containerDirectory: resolver.containerDirectory
        )) { store in
            try await execute(
                resolvedCommand,
                store,
                descriptor.id,
                resolver.containerDirectory)
        }

        let stdout: Data
        switch result.payload {
        case .text(let text):
            stdout = text.isEmpty ? Data() : Data("\(text)\n".utf8)
        case .bytes(let bytes):
            stdout = bytes
        }
        return Output(
            stdout: stdout,
            stderr: Data((result.stderrOutput ?? "").utf8),
            changedWikiID: result.didCommit ? descriptor.id : nil)
    }

    public func runDumpConfig(overlay: String?) throws -> Output {
        let homeDirectory: URL?
        do {
            homeDirectory = try resolveContainer().containerDirectory
        } catch {
            // Dumping the shipped configuration does not require an App Group container.
            homeDirectory = nil
        }
        let result = try DumpConfigCommand.run(
            homeDirectory: homeDirectory,
            overlay: overlay)
        var text = result.note.map { "\($0)\n" } ?? ""
        text += result.output
        if !text.hasSuffix("\n") {
            text += "\n"
        }
        return Output(stdout: Data(text.utf8))
    }

    public func runWikiCreate(name: String) throws -> Output {
        let resolver = try resolveContainer()
        let container = resolver.containerDirectory
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Untitled Wiki" : trimmed
        var descriptor = WikiDescriptor.make(displayName: displayName)
        descriptor.homePageID = try bootstrap.createAndSeed(
            databaseURL: resolver.databaseURL(for: descriptor)).homePageID

        var registry = WikiRegistry.load(from: container)
        registry.add(descriptor)
        try registry.save(to: container)
        return Output(stdout: Data("\(descriptor.id)\t\(descriptor.displayName)\n".utf8))
    }
}

/// Bridges the wikictl CLI's three search commands (`page search`,
/// `source search`, `chat search`) onto the SAME Tantivy BM25 leg the app's
/// sidebar / omnibox use (#637).
///
/// wikictl opens a `GRDBWikiStore` directly and prior to #637 called the
/// 2-arg `store.searchSimilar(query:limit:)` overloads, which forward to the
/// 3-arg path with `bm25Leg: nil` — meaning the store ran its OWN FTS5 leg
/// (now history: #634 dropped FTS5) and never queried the on-disk Tantivy
/// index at `<appGroupContainer>/search-index/<wikiID>/`. That bypassed the
/// Tantivy `fuzzyFields` (edit-distance 1 on title + body, already
/// configured at `Sources/WikiFSSearch/TantivyIndexer.swift:108-111`) and
/// post-#634 means `bm25Leg: nil` has NO BM25 leg at all (cosine-only, empty
/// under `swift test` where NLEmbedding is app-gated).
///
/// This resolver assembles a request-owned search runtime over the SAME on-disk
/// index the app builds and maintains. The index is a derived artifact, so
/// concurrently opening it read-only is safe — SQLite remains the source of
/// truth), runs the kind-scoped search asynchronously via the actor, and resolves the
/// hits to typed summaries (`WikiPageSummary` / `SourceSummary` / `ChatSummary`)
/// via the store's list APIs — preserving Tantivy's best-first rank order, the
/// same mapping `WikiStoreModel.resolveTantivyLeg(query:kind:limit:catalog:)`
/// performs for the sidebar.
///
/// Returns `nil` when Tantivy is unavailable, the index returned nothing, or
/// every hit was missing from the catalog. Post-#634, `nil` means "no BM25
/// leg" — the store's FTS5 fallback was dropped (#634); the cosine leg still
/// answers when NLEmbedding/MLX is available (Swift-side `VectorCosine`,
/// issue #628 — no C scalar). Request-scoped runtime startup rebuilds an empty
/// derived index before querying, including for wikis not yet opened by the app.
public enum CLITantivyLegResolver {
    private enum ProfileSearchError: Error, Sendable {
        case missingTantivyProvider
    }

    struct SearchRequestKey: Hashable, Sendable {
        let wikiID: WikiID
        let containerPath: String
        let query: String
        let kind: TantivyDocumentKind
        let limit: Int
    }

    private struct InFlightSearch: Sendable {
        let token: UUID
        let task: Task<[TantivyShadowSearchResult], Never>
    }

    private actor SearchServicePool {
        private var inFlightSearches: [SearchRequestKey: InFlightSearch] = [:]

        func search(
            wikiID: WikiID,
            containerDirectory: URL,
            store: WikiStore,
            query: String,
            kind: TantivyDocumentKind,
            limit: Int
        ) async -> [TantivyShadowSearchResult] {
            let key = SearchRequestKey(
                wikiID: wikiID,
                containerPath: containerDirectory.standardizedFileURL.path,
                query: query,
                kind: kind,
                limit: limit)

            await runTestSearchHook(key)

            if let existing = inFlightSearches[key] {
                return await existing.task.value
            }

            let token = UUID()
            let task: Task<[TantivyShadowSearchResult], Never> = Task {
                if let testResults = await CLITantivyLegResolver.runTestSearchExecutor(key) {
                    return testResults
                }

                return await CLITantivyLegResolver.runEphemeralSearch(
                    wikiID: wikiID,
                    containerDirectory: containerDirectory,
                    store: store,
                    query: query,
                    kind: kind,
                    limit: limit)
            }
            inFlightSearches[key] = InFlightSearch(token: token, task: task)

            let results = await task.value
            if inFlightSearches[key]?.token == token {
                inFlightSearches.removeValue(forKey: key)
            }
            return results
        }
    }

    private static let searchServicePool = SearchServicePool()

    #if DEBUG
    private actor TestSearchHookBox {
        private var hook: (@Sendable (SearchRequestKey) async -> Void)?

        func install(_ hook: @escaping @Sendable (SearchRequestKey) async -> Void) {
            self.hook = hook
        }

        func reset() {
            hook = nil
        }

        func run(_ key: SearchRequestKey) async {
            await hook?(key)
        }
    }

    private actor TestSearchExecutorBox {
        typealias Executor = @Sendable (SearchRequestKey) async -> [TantivyShadowSearchResult]?

        private var executor: Executor?

        func install(_ executor: @escaping Executor) {
            self.executor = executor
        }

        func reset() {
            executor = nil
        }

        func run(_ key: SearchRequestKey) async -> [TantivyShadowSearchResult]? {
            guard let executor else { return nil }
            return await executor(key)
        }
    }

    private static let testSearchHookBox = TestSearchHookBox()
    private static let testSearchExecutorBox = TestSearchExecutorBox()

    static func installTestSearchHook(
        _ hook: @escaping @Sendable (SearchRequestKey) async -> Void
    ) async {
        await testSearchHookBox.install(hook)
    }

    static func resetTestSearchHook() async {
        await testSearchHookBox.reset()
    }

    static func installTestSearchExecutor(
        _ executor: @escaping @Sendable (SearchRequestKey) async -> [TantivyShadowSearchResult]?
    ) async {
        await testSearchExecutorBox.install(executor)
    }

    static func resetTestSearchExecutor() async {
        await testSearchExecutorBox.reset()
    }

    static func withTestSearchExecutor<Result: Sendable>(
        _ executor: @escaping @Sendable (SearchRequestKey) async -> [TantivyShadowSearchResult]?,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        await installTestSearchExecutor(executor)
        do {
            let result = try await operation()
            await resetTestSearchExecutor()
            return result
        } catch {
            await resetTestSearchExecutor()
            throw error
        }
    }

    private static func runTestSearchHook(_ key: SearchRequestKey) async {
        await testSearchHookBox.run(key)
    }

    private static func runTestSearchExecutor(
        _ key: SearchRequestKey
    ) async -> [TantivyShadowSearchResult]? {
        await testSearchExecutorBox.run(key)
    }
    #else
    private static func runTestSearchHook(_ key: SearchRequestKey) async {}
    private static func runTestSearchExecutor(
        _ key: SearchRequestKey
    ) async -> [TantivyShadowSearchResult]? { nil }
    #endif

    /// Resolve a Tantivy BM25 leg for `wikictl page search`. Returns `nil`
    /// when the index is unavailable/empty — post-#634 that means no BM25
    /// leg (FTS5 was dropped in #634; the cosine leg still answers when
    /// NLEmbedding/MLX is loaded).
    public static func resolvePageLeg(
        wikiID: WikiID,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        limit: Int
    ) async -> [WikiPageSummary]? {
        let hits = await searchServicePool.search(
            wikiID: wikiID,
            containerDirectory: containerDirectory,
            store: store,
            query: query,
            kind: .page,
            limit: limit)
        guard !hits.isEmpty else { return nil }
        let catalog: [WikiPageSummary]
        do {
            catalog = try store.listPages(sortBy: .lastUpdated)
        } catch {
            DebugLog.store("wikictl: listPages(leg) failed for wiki \(wikiID): \(error)")
            return nil
        }
        return resolveHits(hits, catalog: catalog, idFromRawValue: { PageID(rawValue: $0) })
    }

    /// Resolve a Tantivy BM25 leg for `wikictl source search`. Same contract
    /// as ``resolvePageLeg(wikiID:containerDirectory:store:query:limit:)``.
    public static func resolveSourceLeg(
        wikiID: WikiID,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        limit: Int
    ) async -> [SourceSummary]? {
        let hits = await searchServicePool.search(
            wikiID: wikiID,
            containerDirectory: containerDirectory,
            store: store,
            query: query,
            kind: .source,
            limit: limit)
        guard !hits.isEmpty else { return nil }
        let catalog: [SourceSummary]
        do {
            catalog = try store.listSources()
        } catch {
            DebugLog.store("wikictl: listSources(leg) failed for wiki \(wikiID): \(error)")
            return nil
        }
        return resolveHits(hits, catalog: catalog, idFromRawValue: SourceID.init(rawValue:))
    }

    /// Resolve a Tantivy BM25 leg for `wikictl chat search`. Same contract as
    /// ``resolvePageLeg(wikiID:containerDirectory:store:query:limit:)``.
    public static func resolveChatLeg(
        wikiID: WikiID,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        limit: Int
    ) async -> [ChatSummary]? {
        let hits = await searchServicePool.search(
            wikiID: wikiID,
            containerDirectory: containerDirectory,
            store: store,
            query: query,
            kind: .chat,
            limit: limit)
        guard !hits.isEmpty else { return nil }
        let catalog: [ChatSummary]
        do {
            catalog = try store.listChats()
        } catch {
            DebugLog.store("wikictl: listChats(leg) failed for wiki \(wikiID): \(error)")
            return nil
        }
        return resolveHits(hits, catalog: catalog, idFromRawValue: { ChatID(rawValue: $0) })
    }

    // MARK: - Internal

    /// Assemble one request-scoped root and child, await deterministic startup,
    /// query once, then dispose child before root. Failures remain fail-soft at
    /// the CLI boundary and produce no BM25 leg.
    private static func runEphemeralSearch(
        wikiID: WikiID,
        containerDirectory: URL,
        store: WikiStore,
        query: String,
        kind: TantivyDocumentKind,
        limit: Int
    ) async -> [TantivyShadowSearchResult] {
        var profile: BootedProfile?
        var handle: SearchRuntimeHandle?
        do {
            let booted = try await CordisBoot.boot(.init(
                catalog: try CLIPluginCatalog.build(),
                layers: [PatchFile(entries: try ProductionProfiles.cli(homeDirectory: containerDirectory))]))
            profile = booted
            let providers = try await booted.context.require(SearchServiceKeys.providers)
            guard let registration = await providers.resolve(TantivySearchPlugin.key),
                  case .tantivy(let provider) = registration.adapter else {
                throw ProfileSearchError.missingTantivyProvider
            }
            let child = try await booted.context.child()
            let runtime = provider.runtime(
                identity: SearchRuntimeIdentity(
                    wikiID: wikiID,
                    containerDirectory: containerDirectory),
                contentSource: StoreBackedTantivyContentSource(store: store),
                changeStreamFactory: FinishedSearchChangeStreamFactory())
            let assembled = try await runtime.assemble(in: child)
            handle = assembled
            let hits = try await assembled.services.search(
                query: query,
                kinds: [kind],
                limit: limit)
            await dispose(handle: assembled, profile: booted, wikiID: wikiID)
            return hits
        } catch {
            DebugLog.store("wikictl: Tantivy search unavailable for wiki \(wikiID.rawValue): \(error)")
            await dispose(handle: handle, profile: profile, wikiID: wikiID)
            return []
        }
    }

    private static func dispose(
        handle: SearchRuntimeHandle?,
        profile: BootedProfile?,
        wikiID: WikiID
    ) async {
        if let handle {
            do {
                try await handle.dispose()
            } catch {
                DebugLog.store("wikictl: search child cleanup failed for wiki \(wikiID.rawValue): \(error)")
            }
        }
        if let profile {
            do {
                try await profile.shutdown()
            } catch {
                DebugLog.store("wikictl: search profile cleanup failed for wiki \(wikiID.rawValue): \(error)")
            }
        }
    }

    /// Map best-first Tantivy hits to typed summaries via the supplied catalog,
    /// preserving Tantivy's rank order. Mirrors
    /// `WikiStoreModel.resolveTantivyLeg(query:kind:limit:catalog:)` at
    /// `Sources/WikiFSCore/Store/WikiStoreModel.swift:2938` — Tantivy scores
    /// are dropped here because the store's `searchSimilar(query:limit:bm25Leg:)`
    /// treats the leg as a pre-ranked BM25 source and fuses it with the
    /// semantic cosine leg via `RankFusion.rrf`. Returns `nil` (not `[]`)
    /// when nothing resolves so the store runs WITHOUT a BM25 leg (post-#634:
    /// FTS5 is dropped, so a `nil`/empty leg means no lexical results — cosine
    /// still answers when NLEmbedding/MLX is loaded). This matches the
    /// model's contract and is the post-#634 reality all callers route
    /// through: a missing Tantivy leg = "no BM25 leg" (no fallback path), not
    /// an error.
    private static func resolveHits<T: Identifiable & Sendable>(
        _ hits: [TantivyShadowSearchResult],
        catalog: [T],
        idFromRawValue: (String) -> T.ID
    ) -> [T]? {
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resolved = hits.compactMap { hit -> T? in
            let id = idFromRawValue(hit.ulid)
            return byID[id]
        }
        return resolved.isEmpty ? nil : resolved
    }
}

#else
public enum CLIStoreProfileError: Error {
    case incompatibleStore
    case operationAndCleanup(operation: any Error, cleanup: any Error)
}

public enum CLIStoreProfile {
    public static func withStore<Result>(
        databaseURL: URL,
        wikiID: WikiID,
        containerDirectory: URL,
        operation: (GRDBWikiStore) async throws -> Result
    ) async throws -> Result {
        let service = try StoreBackend.current.makeStore(databaseURL: databaseURL)
        guard let store = service as? GRDBWikiStore else {
            throw CLIStoreProfileError.incompatibleStore
        }
        return try await operation(store)
    }
}

/// Linux stub: Tantivy is unavailable. All resolvers return nil (no BM25 leg).
public enum CLITantivyLegResolver {
    public static func resolvePageLeg(
        wikiID: WikiID, containerDirectory: URL, store: WikiStore,
        query: String, limit: Int
    ) async -> [WikiPageSummary]? { nil }

    public static func resolveSourceLeg(
        wikiID: WikiID, containerDirectory: URL, store: WikiStore,
        query: String, limit: Int
    ) async -> [SourceSummary]? { nil }

    public static func resolveChatLeg(
        wikiID: WikiID, containerDirectory: URL, store: WikiStore,
        query: String, limit: Int
    ) async -> [ChatSummary]? { nil }
}
#endif
