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

    /// The open-seam harness variant: mounts the plugin with injected
    /// storage-open factories. Composition identity (id, provisions, config)
    /// is unchanged, so catalogs built with it behave like the production one.
    public static func definition(openFactories: StoreOpenFactories) -> PluginDefinition {
        makeDefinition(openFactories: openFactories)
    }

    /// Injected storage-open factories for the open-seam harness
    /// (plans/daemon-only-access.md Phase 0). `nil` legs keep the production
    /// constructors (the `StoreBackend` factory and the read-only pool's
    /// read-only connection constructor). Recording
    /// legs let `ClientLocalOpenBoundaryTests` count client-side opens; the
    /// daemon and CLI compositions never inject them.
    public struct StoreOpenFactories: Sendable {
        public let makeStore: (@Sendable (URL) throws -> any WikiStore)?
        public let makeReadOnlyStore: WikiReadService.ReadOnlyStoreFactory?

        public init(
            makeStore: (@Sendable (URL) throws -> any WikiStore)? = nil,
            makeReadOnlyStore: WikiReadService.ReadOnlyStoreFactory? = nil
        ) {
            self.makeStore = makeStore
            self.makeReadOnlyStore = makeReadOnlyStore
        }

        public static let production = StoreOpenFactories()
    }

    static func makeDefinition(
        beforeForward: @escaping StoreEventForwarder.BeforeEmit = { _ in },
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
            let store: any WikiStore
            if let makeStore = openFactories.makeStore {
                store = try makeStore(databaseURL)
            } else {
                store = try StoreBackend.current.makeStore(databaseURL: databaseURL)
            }
            // Headless daemon profile: project renderer source-type claims
            // from the authoritative machine index (WebKit-free, best-effort).
            store.registeredRendererSourceTypes = await RendererCatalogResolution.productionSourceTypes()
            let bus = WikiEventBus(wikiID: WikiID(rawValue: config.wikiID))
            store.eventBus = bus
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
