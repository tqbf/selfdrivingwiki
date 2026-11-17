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
    ///   - mode: the resolved `allowLocalStore` mode (plans/daemon-only-access.md,
    ///     "Flag name and polarity"). `.remote` provisions the store through
    ///     the injected factory (the app's daemon-backed client) and NEVER
    ///     opens a local database; `.local` is today's local composition.
    ///     The app catalog passes the launch-fixed resolved mode; daemon and
    ///     CLI catalogs keep the plain `definition` (always `.local` — they
    ///     own the file).
    ///   - openFactories: injected open factories. `nil` legs keep the
    ///     production constructors (`.local` only — see the gate below).
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
    /// constructors (the `StoreBackend` factory and the read-only pool's
    /// read-only connection constructor) — available in `.local` mode only.
    /// Recording legs let `ClientLocalOpenBoundaryTests` count client-side
    /// opens; the daemon and CLI compositions never inject them.
    public struct StoreOpenFactories: Sendable {
        public let makeStore: (@Sendable (StoreOpenContext) throws -> any WikiStore)?
        public let makeReadOnlyStore: WikiReadService.ReadOnlyStoreFactory?

        public init(
            makeStore: (@Sendable (StoreOpenContext) throws -> any WikiStore)? = nil,
            makeReadOnlyStore: WikiReadService.ReadOnlyStoreFactory? = nil
        ) {
            self.makeStore = makeStore
            self.makeReadOnlyStore = makeReadOnlyStore
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
            ServiceDependency(StoreServiceKeys.readService),
        ],
        config: StoreConfig.self
    ) { config in
        try ComponentDefinition(
            label: "wiki.store",
            provisions: [
                ServiceDependency(StoreServiceKeys.store),
                ServiceDependency(StoreServiceKeys.readService),
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
            // The read-only pool stays in BOTH modes through P4 (the P3
            // waiver row: the semantic-search leg still reads locally). Its
            // connections open lazily and read-only; the wiki STORE open
            // above is the seam this file's mode gate controls.
            let readService = WikiReadService(
                databaseURL: databaseURL,
                makeReadOnlyStore: openFactories.makeReadOnlyStore)
            let forwarder = StoreEventForwarder(
                activation: activation,
                beforeEmit: beforeForward)
            let token = bus.subscribe(nil) { event in
                Task { await forwarder.submit(event) }
            }
            _ = try await activation.effect { _ in
                await forwarder.shutdown { bus.unsubscribe(token) }
                await readService.shutdown()
            }
            _ = try await activation.supply(StoreServiceKeys.store, value: store)
            _ = try await activation.supply(StoreServiceKeys.readService, value: readService)
        }
    }
    }
}
