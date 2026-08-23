import Cordis
import WikiFSCore

public enum SessionsPlugin {
    public static let id = PluginID("wiki.sessions")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki sessions",
        dependencies: [ServiceDependency(StoreServiceKeys.store)],
        provisions: [ServiceDependency(SessionServiceKeys.sessions)]
    ) {
        try ComponentDefinition(
            label: "wiki.sessions",
            dependencies: [ServiceDependency(StoreServiceKeys.store)],
            provisions: [ServiceDependency(SessionServiceKeys.sessions)]
        ) { activation in
            _ = try await activation.require(StoreServiceKeys.store)
            let service = SessionLogService { batch in
                await activation.emit(SessionEventKeys.appended, batch)
            }
            _ = try await activation.supply(SessionServiceKeys.sessions, value: service)
        }
    }
}

public enum ChatsPersistencePlugin {
    public static let id = PluginID("wiki.chats-persistence")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki chat persistence",
        dependencies: [ServiceDependency(StoreServiceKeys.store)]
    ) {
        try ComponentDefinition(
            label: "wiki.chats-persistence",
            dependencies: [ServiceDependency(StoreServiceKeys.store)]
        ) { activation in
            let store = try await activation.require(StoreServiceKeys.store)
            _ = try await activation.on(SessionEventKeys.appended) { batch in
                let persistable = batch.events.filter(\.isPersistable)
                guard !persistable.isEmpty else { return }
                try store.appendChatMessages(chatID: batch.chatID, events: persistable)
            }
        }
    }
}
