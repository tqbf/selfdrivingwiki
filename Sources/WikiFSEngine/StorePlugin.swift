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

public enum StorePlugin {
    public static let id = PluginID("wiki.store")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki store",
        provisions: [
            ServiceDependency(StoreServiceKeys.store),
            ServiceDependency(StoreServiceKeys.readPool),
        ],
        config: StoreConfig.self
    ) { config in
        try ComponentDefinition(
            label: "wiki.store",
            provisions: [
                ServiceDependency(StoreServiceKeys.store),
                ServiceDependency(StoreServiceKeys.readPool),
            ]
        ) { activation in
            let databaseURL = URL(fileURLWithPath: config.databasePath, isDirectory: false)
            var store: any WikiStore = try StoreBackend.current.makeStore(databaseURL: databaseURL)
            let bus = WikiEventBus(wikiID: WikiID(rawValue: config.wikiID))
            store.eventBus = bus
            let readPool = WikiReadPool(databaseURL: databaseURL)

            let token = bus.subscribe(nil) { event in
                    Task {
                        await activation.emit(StoreEventKeys.resourceChange, event)
                    }
                }
            _ = try await activation.effect { _ in
                bus.unsubscribe(token)
            }
            _ = try await activation.supply(StoreServiceKeys.store, value: store)
            _ = try await activation.supply(StoreServiceKeys.readPool, value: readPool)
        }
    }
}
