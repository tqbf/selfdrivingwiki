import Cordis
import Foundation
import WikiFSCore
import WikiFSTypes

public struct StoreConfig: PluginConfig, Equatable {
    public let databasePath: String
    public let wikiID: String

    public init(databasePath: String, wikiID: String) {
        self.databasePath = databasePath
        self.wikiID = wikiID
    }

    public static func validate(_ config: StoreConfig) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check(
            "databasePath",
            !config.databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "database path must not be empty")
        validation.check(
            "wikiID",
            !config.wikiID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "wiki id must not be empty")
        return validation.allIssues
    }
}

actor StoreEventForwarder {
    typealias BeforeEmit = @Sendable (ResourceChangeEvent) async -> Void

    private let activation: ActivationContext
    private let beforeEmit: BeforeEmit
    private var accepting = true
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(
        activation: ActivationContext,
        beforeEmit: @escaping BeforeEmit = { _ in }
    ) {
        self.activation = activation
        self.beforeEmit = beforeEmit
    }

    func submit(_ event: ResourceChangeEvent) {
        guard accepting else { return }
        let id = UUID()
        tasks[id] = Task { [weak self, activation, beforeEmit] in
            await beforeEmit(event)
            guard !Task.isCancelled else { return }
            await activation.emit(StoreEventKeys.resourceChange, event)
            await self?.completed(id)
        }
    }

    func shutdown(unsubscribe: @Sendable () -> Void) async {
        guard accepting else { return }
        accepting = false
        unsubscribe()
        let pending = Array(tasks.values)
        tasks.removeAll()
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }

    private func completed(_ id: UUID) {
        tasks.removeValue(forKey: id)
    }
}

public enum StorePlugin {
    public static let id = PluginID("wiki.store")

    public static let definition = makeDefinition()

    /// The open-seam harness / injected-store variant: mounts the plugin
    /// with a resolved store-access mode and injected storage-open
    /// factories. Composition identity (id, provisions, config) is
    /// unchanged, so catalogs built with it behave like the production one.
    ///
    /// - Parameters:
    ///   - mode: the resolved store-access mode (plans/daemon-only-access.md).
    ///     `.remote` provisions the store through the injected factory (the
    ///     app's daemon-backed client) and NEVER opens a local database;
    ///     `.local` is the daemon/CLI/test composition (they own the file).
    ///   - openFactories: injected open factory. `nil` keeps the production
    ///     constructor (`.local` only — see the gate below).
    public static func definition(
        mode: StoreAccessMode = .local,
        openFactories: StoreOpenFactories = .production
    ) -> PluginDefinition {
        makeDefinition(mode: mode, openFactories: openFactories)
    }

    /// Per-wiki identity + location handed to an injected `makeStore`
    /// factory. The remote factory ignores `databaseURL` (the daemon owns
    /// the file) and needs `wikiID` to scope its wire operations; the local
    /// recording factories use the URL as the attribution label.
    public struct StoreOpenContext: Sendable {
        public let databaseURL: URL
        public let wikiID: String

        public init(databaseURL: URL, wikiID: String) {
            self.databaseURL = databaseURL
            self.wikiID = wikiID
        }
    }

    /// Injected storage-open factories for the open-seam harness and the
    /// app's remote-store injection (plans/daemon-only-access.md Phase 0
    /// harness, Phase 3 cutover). `nil` legs keep the production
    /// constructor (the `StoreBackend` factory) — available in `.local`
    /// mode only. Recording legs let `ClientLocalOpenBoundaryTests` count
    /// client-side opens; the daemon and CLI compositions never inject
    /// them. (P5: the read-only-pool leg is REMOVED — the pool no longer
    /// exists in app composition; the read-pool freedom-guard row is `none`.)
    public struct StoreOpenFactories: Sendable {
        public let makeStore: (@Sendable (StoreOpenContext) throws -> any WikiStore)?

        public init(
            makeStore: (@Sendable (StoreOpenContext) throws -> any WikiStore)? = nil
        ) {
            self.makeStore = makeStore
        }

        /// The app-layer remote injection (plans/daemon-only-access.md
        /// Placement — the `makeDaemonTransport` pattern): one factory
        /// producing the daemon-backed store per booted wiki session. The
        /// wiki id arrives through the per-wiki context; the context's
        /// database URL is ignored (the daemon owns that file).
        public static func remoteStore(
            _ store: @escaping @Sendable (StoreOpenContext) -> any WikiStore
        ) -> StoreOpenFactories {
            StoreOpenFactories(makeStore: store)
        }

        /// Whether the injected factories satisfy `mode`'s provisioning
        /// contract. `.remote` REQUIRES a store factory: the catalog
        /// build consults this and fails explicitly rather than letting a
        /// session boot fall back to a local store.
        public func satisfies(_ mode: StoreAccessMode) -> Bool {
            switch mode {
            case .remote: return makeStore != nil
            case .local: return true
            }
        }

        public static let production = StoreOpenFactories()
    }

    static func makeDefinition(
        beforeForward: @escaping StoreEventForwarder.BeforeEmit = { _ in },
        mode: StoreAccessMode = .local,
        openFactories: StoreOpenFactories = .production
    ) -> PluginDefinition {
        PluginDefinition(
        id: id,
        label: "Wiki store",
        provisions: [
            ServiceDependency(StoreServiceKeys.store),
        ],
        config: StoreConfig.self
    ) { config in
        try ComponentDefinition(
            label: "wiki.store",
            provisions: [
                ServiceDependency(StoreServiceKeys.store),
            ]
        ) { activation in
            let databaseURL = URL(fileURLWithPath: config.databasePath, isDirectory: false)
            // The mode gate (plans/daemon-only-access.md Placement + the P3
            // column): the injected factory decides WHAT is constructed;
            // the resolved mode decides whether a LOCAL open may happen at
            // all.
            //
            // - factory present + `.remote`: the factory provisions the
            //   daemon-backed store (the app's RemoteWikiStore). No local
            //   GRDBWikiStore is opened — the daemon owns the file. This is
            //   the shipping composition.
            // - factory present + `.local`: the recording/harness factory
            //   opens (and records) the local store — the open-seam
            //   harness's P0/P2 behavior, unchanged.
            // - factory absent + `.local`: the production local open,
            //   unchanged (daemon, CLI, and the DEBUG app override).
            // - factory absent + `.remote`: FAIL EXPLICITLY. Falling back
            //   to a local open here would silently revive a second writer.
            let store: any WikiStore
            if let makeStore = openFactories.makeStore {
                store = try makeStore(StoreOpenContext(
                    databaseURL: databaseURL,
                    wikiID: config.wikiID))
            } else if mode == .local {
                store = try StoreBackend.current.makeStore(databaseURL: databaseURL)
            } else {
                throw StoreModeError.remoteModeRefusesLocalStoreOpen(
                    wikiID: config.wikiID)
            }
            // Headless daemon profile: project renderer source-type claims
            // from the authoritative machine index (WebKit-free, best-effort).
            store.registeredRendererSourceTypes = await RendererCatalogResolution.productionSourceTypes()
            let bus = WikiEventBus(wikiID: WikiID(rawValue: config.wikiID))
            store.eventBus = bus
            // P5: no read-only pool. The read-pool freedom-guard row is
            // `none` — the semantic-search leg moved to the daemon (its
            // executor resolves the BM25 leg and its store computes the
            // cosine leg), and the queue UI's closed-wiki names read through
            // the daemon store family. Nothing in app composition reads a
            // wiki database file directly anymore.
            let forwarder = StoreEventForwarder(
                activation: activation,
                beforeEmit: beforeForward)
            let token = bus.subscribe(nil) { event in
                Task { await forwarder.submit(event) }
            }
            _ = try await activation.effect { _ in
                await forwarder.shutdown { bus.unsubscribe(token) }
            }
            _ = try await activation.supply(StoreServiceKeys.store, value: store)
        }
    }
    }
}
