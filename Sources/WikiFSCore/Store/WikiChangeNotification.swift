import Foundation

/// The Darwin-notification contract between `wikictl` (the writer) and the app
/// (the change bridge), shared so the two sides can NEVER drift on the name.
///
/// ## Why the name carries the wiki id
///
/// `wikictl` writes straight to a wiki's `<ulid>.sqlite`; the app must then (a)
/// rebuild its sidebar if that wiki is on screen and (b) `signalChange()` on
/// that wiki's File Provider domain. So the app has to learn **which** wiki
/// changed.
///
/// Darwin notifications (`notify_post` / `CFNotificationCenterGetDarwinNotifyCenter`)
/// **carry no payload** — you cannot attach the wiki id as data. The id therefore
/// has to live in the notification NAME. We post a PER-WIKI name,
/// `org.sockpuppet.wiki.changed.<wikiID>`, and the app subscribes to exactly that
/// name for each registered wiki (it already knows every wiki's id from the
/// registry). The app's observer closure then knows the id with no demux table.
///
/// (Rejected alternative: a single generic `org.sockpuppet.wiki.changed` name +
/// the app refreshing *all* wikis. That re-signals every domain on every CLI
/// write — wasteful with N wikis — and loses the "which wiki" the doc wants the
/// app to learn. The per-wiki name is the doc-intended approach.)
public enum WikiChangeNotification {
    /// The base name. Never posted on its own — every post/observe uses the
    /// per-wiki variant below. Kept public for documentation / tests.
    public static let baseName = "org.sockpuppet.wiki.changed"

    /// The concrete Darwin-notification name for one wiki:
    /// `org.sockpuppet.wiki.changed.<wikiID>`. The wiki id is a ULID
    /// (Crockford base32 — only `A–Z0–9`, no dots), so it can't collide with the
    /// dotted base name or smear across the separator.
    public static func name(forWikiID id: String) -> String {
        "\(baseName).\(id)"
    }
}
