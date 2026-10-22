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

    public var resolveRendererCatalog: @Sendable () async -> RegisteredRendererSourceTypes =
        { await RendererCatalogResolution.productionSourceTypes() }

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
            // Headless CLI profile: project source-type claims from the
            // authoritative machine index (WebKit-free, best-effort).
            store.registeredRendererSourceTypes = await resolveRendererCatalog()
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
    private let daemonCommandRouter: DaemonCommandRouter
    private let execute: CommandExecutor

    public init(
        resolveContainer: @escaping () throws -> WikiResolver = WikiResolver.appGroupContainer,
        storeProfile: CLIStoreProfile = CLIStoreProfile(),
        daemonCommandRouter: DaemonCommandRouter = DaemonCommandRouter(),
        execute: @escaping CommandExecutor
    ) {
        self.resolveContainer = resolveContainer
        self.storeProfile = storeProfile
        self.daemonCommandRouter = daemonCommandRouter
        self.execute = execute
    }

    public func runOrdinary(
        command: ArgumentParser.Command,
        wikiSelector: String,
        databasePath: String = "",
        environment: [String: String]
    ) async throws -> Output {
        let resolvedCommand = ArgumentParser.applyEnv(command, env: environment)
        let resolver = try resolveContainer()
        // Raw selector strings become a typed WikiSelection HERE — the single
        // boundary where an explicit database path is validated (absolute,
        // .sqlite, outside the App Group container) and mixed selector forms
        // are rejected.
        let selection = try WikiResolver.selection(
            wikiSelector: wikiSelector.isEmpty ? nil : wikiSelector,
            databasePath: databasePath.isEmpty ? nil : databasePath)
        // Phase 3 of plans/cli-domain-commands.md: MIGRATED read-only commands
        // execute on the daemon over the domain envelope and never open the
        // wiki database here. Anything not migrated (Phase 4 writes, the
        // search commands until their server-side resolution lands) and every
        // explicit `--database-path` fixture run keeps the in-process path
        // below.
        if case .registry(let selector) = selection,
           let call = DaemonCommandRoute.call(for: resolvedCommand) {
            let routed = try await daemonCommandRouter.run(
                call,
                selector: selector,
                containerDirectory: resolver.containerDirectory)
            return Self.output(
                for: routed.result,
                command: resolvedCommand,
                changedWikiID: routed.result.didCommit ? routed.wikiID : nil)
        }
        let target = try resolver.resolve(selection: selection)
        let result = try await storeProfile.withStore(request: CLIStoreProfile.Request(
            databaseURL: target.databaseURL,
            wikiID: target.wikiID,
            containerDirectory: target.containerDirectory
        )) { store in
            try await execute(
                resolvedCommand,
                store,
                target.wikiID,
                target.containerDirectory)
        }

        return Self.output(
            for: result,
            command: resolvedCommand,
            changedWikiID: result.didCommit ? target.wikiID : nil)
    }

    static func output(
        for result: SourceCommand.Result,
        command: ArgumentParser.Command,
        changedWikiID: WikiID? = nil
    ) -> Output {
        let stdout: Data
        let outputText: String?
        switch result.payload {
        case .text(let text):
            outputText = text
            stdout = text.isEmpty ? Data() : Data("\(text)\n".utf8)
        case .bytes(let bytes):
            outputText = nil
            stdout = bytes
        }
        var stderrText = result.stderrOutput ?? ""
        if let outputText,
           let trailer = CLIReference.helpTrailer(for: command, output: outputText)
        {
            if !stderrText.isEmpty, !stderrText.hasSuffix("\n") {
                stderrText += "\n"
            }
            stderrText += trailer
        }
        return Output(
            stdout: stdout,
            stderr: Data(stderrText.utf8),
            changedWikiID: changedWikiID)
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

    // `runWikiCreate` was removed in Phase 2 of plans/cli-domain-commands.md:
    // wiki creation runs on the daemon (its creation coordinator bootstraps,
    // seeds, and registers the wiki) through `DaemonWikiRegistryClient`. The
    // CLI's direct `StoreBootstrap.createAndSeed` + `wikis.json` write path is
    // gone — the daemon is the single writer of wiki lifecycle state.
}

/// Bridges the wikictl CLI's three search commands (`page search`,
/// `source search`, `chat search`) onto the daemon's index — the same BM25
/// leg the app's sidebar / omnibox use (#637), served by the daemon as the
/// sole index owner. The CLI never touches a Tantivy index directory and
/// never boots a search runtime of its own. Requests use the daemon's local
/// socket through ``DaemonSearchClient``, deduplicated per
/// (wiki, query, kind, limit) while a request is in flight.
///
/// Hits are mapped best-first to typed summaries (`WikiPageSummary` /
/// `SourceSummary` / `ChatSummary`) via the store's list APIs, preserving
/// rank order. Hits naming ids absent from the current catalog are dropped.
///
/// A successful search with no hits — or with no hit resolving to the
/// catalog — returns `nil` (no BM25 leg). Daemon connection, timeout, and
/// wire failures throw to the CLI, which reports a runtime error instead of
/// a false successful no-hit result. There is no local fallback: an
/// unreachable daemon fails loudly.
public enum CLITantivyLegResolver {
    struct SearchRequestKey: Hashable, Sendable {
        let wikiID: WikiID
        let query: String
        let kind: TantivyDocumentKind
        let limit: Int
    }

    private struct InFlightSearch: Sendable {
        let token: UUID
        let task: Task<Result<[TantivyShadowSearchResult], any Error>, Never>
    }

    private actor SearchServicePool {
        private var inFlightSearches: [SearchRequestKey: InFlightSearch] = [:]
        private var daemonClient: DaemonSearchClient?

        /// The standalone CLI uses the daemon's shared local socket.
        /// Embedded XPC service lookup is available only to the host app.
        private func daemonBackend() throws -> DaemonSearchClient {
            if let daemonClient { return daemonClient }
            let directory = try DatabaseLocation.appGroupContainerDirectory()
            let transport = try DaemonSearchSocketClient.transport(containerDirectory: directory)
            let client = DaemonSearchClient(transport: transport)
            daemonClient = client
            return client
        }

        func search(key: SearchRequestKey) async throws -> [TantivyShadowSearchResult] {
            if let existing = inFlightSearches[key] {
                return try await existing.task.value.get()
            }

            let token = UUID()
            let task: Task<Result<[TantivyShadowSearchResult], any Error>, Never> = Task {
                do {
                    #if DEBUG
                    if let injected = try await CLITantivyLegResolver.runTestSearchBackend(key) {
                        return .success(injected)
                    }
                    #endif

                    let client = try daemonBackend()
                    return .success(try await client.search(
                        wikiID: key.wikiID,
                        query: key.query,
                        kinds: [key.kind],
                        limit: key.limit))
                } catch {
                    return .failure(error)
                }
            }
            inFlightSearches[key] = InFlightSearch(token: token, task: task)

            let result = await task.value
            if inFlightSearches[key]?.token == token {
                inFlightSearches.removeValue(forKey: key)
            }
            return try result.get()
        }
    }

    private static let searchServicePool = SearchServicePool()

    #if DEBUG
    /// Test seam: the injected backend replaces the daemon call entirely —
    /// when one is installed, no XPC connection is ever created. Tests use it
    /// to exercise summary mapping, dedup, and error propagation without a
    /// daemon.
    private actor TestSearchBackendBox {
        typealias Backend = @Sendable (SearchRequestKey) async throws -> [TantivyShadowSearchResult]

        private var backend: Backend?

        func install(_ backend: @escaping Backend) {
            self.backend = backend
        }

        func reset() {
            backend = nil
        }

        /// `nil` when no backend is installed (fall through to the daemon);
        /// otherwise the backend's result IS the answer.
        func run(_ key: SearchRequestKey) async throws -> [TantivyShadowSearchResult]? {
            guard let backend else { return nil }
            return try await backend(key)
        }
    }

    private static let testSearchBackendBox = TestSearchBackendBox()

    static func installTestSearchBackend(
        _ backend: @escaping @Sendable (SearchRequestKey) async throws -> [TantivyShadowSearchResult]
    ) async {
        await testSearchBackendBox.install(backend)
    }

    static func resetTestSearchBackend() async {
        await testSearchBackendBox.reset()
    }

    static func runTestSearchBackend(
        _ key: SearchRequestKey
    ) async throws -> [TantivyShadowSearchResult]? {
        try await testSearchBackendBox.run(key)
    }

    static func withTestSearchBackend<Result: Sendable>(
        _ backend: @escaping @Sendable (SearchRequestKey) async throws -> [TantivyShadowSearchResult],
        operation: () async throws -> Result
    ) async rethrows -> Result {
        await installTestSearchBackend(backend)
        do {
            let result = try await operation()
            await resetTestSearchBackend()
            return result
        } catch {
            await resetTestSearchBackend()
            throw error
        }
    }
    #else
    static func runTestSearchBackend(
        _ key: SearchRequestKey
    ) async throws -> [TantivyShadowSearchResult]? { nil }
    #endif

    /// Resolve the daemon's BM25 leg for `wikictl page search`. Returns `nil`
    /// when the daemon answers no hits — that means no BM25 leg (the store
    /// runs without a lexical leg; the cosine leg still answers when
    /// NLEmbedding/MLX is loaded).
    public static func resolvePageLeg(
        wikiID: WikiID,
        store: WikiStore,
        query: String,
        limit: Int
    ) async throws -> [WikiPageSummary]? {
        let hits = try await searchServicePool.search(key: SearchRequestKey(
            wikiID: wikiID,
            query: query,
            kind: .page,
            limit: limit))
        guard !hits.isEmpty else { return nil }
        let catalog = try store.listPages(sortBy: .lastUpdated)
        return resolveHits(hits, catalog: catalog, idFromRawValue: { PageID(rawValue: $0) })
    }

    /// Resolve the daemon's BM25 leg for `wikictl source search`. Same contract
    /// as ``resolvePageLeg(wikiID:store:query:limit:)``.
    public static func resolveSourceLeg(
        wikiID: WikiID,
        store: WikiStore,
        query: String,
        limit: Int
    ) async throws -> [SourceSummary]? {
        let hits = try await searchServicePool.search(key: SearchRequestKey(
            wikiID: wikiID,
            query: query,
            kind: .source,
            limit: limit))
        guard !hits.isEmpty else { return nil }
        let catalog = try store.listSources()
        return resolveHits(hits, catalog: catalog, idFromRawValue: SourceID.init(rawValue:))
    }

    /// Resolve the daemon's BM25 leg for `wikictl chat search`. Same contract as
    /// ``resolvePageLeg(wikiID:store:query:limit:)``.
    public static func resolveChatLeg(
        wikiID: WikiID,
        store: WikiStore,
        query: String,
        limit: Int
    ) async throws -> [ChatSummary]? {
        let hits = try await searchServicePool.search(key: SearchRequestKey(
            wikiID: wikiID,
            query: query,
            kind: .chat,
            limit: limit))
        guard !hits.isEmpty else { return nil }
        let catalog = try store.listChats()
        return resolveHits(hits, catalog: catalog, idFromRawValue: { ChatID(rawValue: $0) })
    }

    // MARK: - Internal

    /// Map best-first Tantivy hits to typed summaries via the supplied catalog,
    /// preserving rank order. Mirrors
    /// `WikiStoreModel.resolveTantivyLeg(query:kind:limit:catalog:)` — Tantivy
    /// scores are dropped here because the store's
    /// `searchSimilar(query:limit:bm25Leg:)` treats the leg as a pre-ranked
    /// BM25 source and fuses it with the semantic cosine leg via
    /// `RankFusion.rrf`. Returns `nil` (not `[]`) when nothing resolves so the
    /// store runs WITHOUT a BM25 leg — a missing leg is "no BM25 results", not
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
    /// The catalog resolver for headless store opens. Injectable so tests can
    /// prove the wiring without machine package state.
    public static var resolveRendererCatalog: @Sendable () async -> RegisteredRendererSourceTypes =
        { await RendererCatalogResolution.productionSourceTypes() }

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
        // Headless profiles project source-type claims straight from the
        // authoritative machine index (WebKit-free). A failure keeps the
        // empty catalog and never blocks the command.
        store.registeredRendererSourceTypes = await resolveRendererCatalog()
        return try await operation(store)
    }
}

/// Linux stub: Tantivy is unavailable. All resolvers return nil (no BM25 leg).
public enum CLITantivyLegResolver {
    public static func resolvePageLeg(
        wikiID: WikiID, store: WikiStore,
        query: String, limit: Int
    ) async throws -> [WikiPageSummary]? { nil }

    public static func resolveSourceLeg(
        wikiID: WikiID, store: WikiStore,
        query: String, limit: Int
    ) async throws -> [SourceSummary]? { nil }

    public static func resolveChatLeg(
        wikiID: WikiID, store: WikiStore,
        query: String, limit: Int
    ) async throws -> [ChatSummary]? { nil }
}
#endif
