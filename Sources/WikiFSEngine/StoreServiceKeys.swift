import Cordis
import WikiFSCore
import WikiFSTypes

/// Stable Cordis identities for the wiki store domain seam.
public enum StoreServiceKeys {
    public static let store = ServiceKey<any WikiStore>(label: "wiki.store")
    public static let readService = ServiceKey<WikiReadService>(label: "wiki.store.read-service")
}

/// Cordis event surfaces emitted by the store plugin.
public enum StoreEventKeys {
    public static let resourceChange = EventKey<ResourceChangeEvent, EmitMode>(
        label: "wiki.resource-change")
}
