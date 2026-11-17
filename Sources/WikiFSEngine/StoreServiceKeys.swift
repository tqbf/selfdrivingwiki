import Cordis
import WikiFSCore
import WikiFSTypes

/// Stable Cordis identities for the wiki store domain seam.
public enum StoreServiceKeys {
    public static let store = ServiceKey<any WikiStore>(label: "wiki.store")
    // P5: the read-service key is gone with `WikiReadService` itself — the
    // read-only pool left app composition (the read-pool freedom-guard row
    // is `none`); nothing provisions or requires it anymore.
}

/// Cordis event surfaces emitted by the store plugin.
public enum StoreEventKeys {
    public static let resourceChange = EventKey<ResourceChangeEvent, EmitMode>(
        label: "wiki.resource-change")
}
