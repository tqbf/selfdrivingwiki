import Foundation

/// The Darwin-notification contract between `wikictl` / the `wikid` daemon (the
/// writers) and the app (the change bridge), shared so the two sides can NEVER
/// drift on the name.
///
/// ## One stable name, no payload, no subscription set
///
/// `wikictl` writes straight to a wiki's `<ulid>.sqlite`; the app must then (a)
/// rebuild its sidebar if that wiki is on screen and (b) `signalChange()` on
/// that wiki's File Provider domain.
///
/// Darwin notifications (`notify_post` / `CFNotificationCenterGetDarwinNotifyCenter`)
/// **carry no payload** — you cannot attach a wiki id as data. An earlier design
/// therefore encoded the id in the NAME (`org.sockpuppet.wiki.changed.<wikiID>`)
/// and had the app subscribe to one name per registered wiki. That design cannot
/// hear a wiki it does not already know about: a wiki created while the app is
/// running is absent from the app's subscription set, so its posts were neither
/// received nor resolvable, and its writes never reached the UI (#1374).
///
/// This is therefore ONE stable name, posted as a payload-free "something
/// changed" signal. The consumer re-reads the authoritative state — the wiki
/// registry — to learn which wikis exist, exactly as
/// `AgentProvidersConfigStore.darwinNotificationName` and
/// `ExtractorCatalogChangeNotification.darwinName` do for their sidecars. There
/// is no subscription set, so no subscription set can go stale.
///
/// The trade: the name alone cannot say WHICH wiki changed, so the app refreshes
/// every wiki in the registry (see `WikiChangeWakeRouting` and
/// `WikiChangeBridge`). The registry holds a handful of wikis and the extra work
/// is one idempotent File Provider signal each — hearing every write is worth
/// more than saving those signals.
public enum WikiChangeNotification {
    /// The one Darwin-notification name for a committed wiki change. Posted on
    /// its own — there is no per-wiki variant — and observed once at launch.
    public static let baseName = "org.sockpuppet.wiki.changed"
}

public enum RendererChangeNotification {
    public static let wikiBaseName = "org.sockpuppet.wiki.renderers.wiki.changed"
    public static let machineBaseName = "org.sockpuppet.wiki.renderers.machine.changed"

    public static func wikiName(forWikiID id: WikiID) -> String {
        "\(wikiBaseName).\(id.rawValue)"
    }

    public static func machineName(for scopeID: RendererMachineScopeID) -> String {
        "\(machineBaseName).\(scopeID.rawValue)"
    }
}
