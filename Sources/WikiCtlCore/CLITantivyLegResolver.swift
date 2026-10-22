import Foundation
import WikiFSCore

#if os(macOS)
import Cordis
import CordisLoader
import WikiFSEngine

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

    private let resolveContainer: () throws -> WikiResolver
    private let daemonCommandRouter: DaemonCommandRouter

    public init(
        resolveContainer: @escaping () throws -> WikiResolver = WikiResolver.appGroupContainer,
        daemonCommandRouter: DaemonCommandRouter = DaemonCommandRouter()
    ) {
        self.resolveContainer = resolveContainer
        self.daemonCommandRouter = daemonCommandRouter
    }

    /// Run one ordinary parsed command. EVERY command rides the daemon (Phase
    /// 5 of plans/cli-domain-commands.md): the daemon resolves the `--wiki`
    /// selector against its live registry and executes the command layer
    /// against its prepared store. There is NO local store leg here — since
    /// the fixture-binary split (§"The fixture binary") an in-process store
    /// boot exists only in the separate build-only `wikictl-fixture` binary,
    /// and a command with no daemon route is a wikictl wiring bug that fails
    /// loudly instead of silently opening a local store.
    public func runOrdinary(
        command: ArgumentParser.Command,
        wikiSelector: String,
        environment: [String: String]
    ) async throws -> Output {
        let resolvedCommand = ArgumentParser.applyEnv(command, env: environment)
        let resolver = try resolveContainer()
        guard let call = DaemonCommandRoute.call(for: resolvedCommand) else {
            throw PageCommand.Failure.message(
                "no daemon route for this wikictl command — every --wiki command "
                    + "must ride the daemon, and there is no local fallback; "
                    + "this is a wikictl wiring bug")
        }
        let routed = try await daemonCommandRouter.run(
            call,
            selector: wikiSelector,
            containerDirectory: resolver.containerDirectory)
        return Self.output(
            for: routed.result,
            command: resolvedCommand,
            changedWikiID: routed.result.didCommit ? routed.wikiID : nil)
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
