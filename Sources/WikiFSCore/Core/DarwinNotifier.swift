import Foundation

/// Posts the per-wiki Darwin notification after a committing write (wikictl or
/// the daemon), so the app's change bridge can refresh the sidebar and signal
/// the File Provider.
///
/// Darwin notifications carry no payload, so the wiki id lives in the NAME
/// (`WikiChangeNotification.name(forWikiID:)`). The poster posts ONLY this — it
/// never signals the File Provider itself; that stays the app's job (single owner
/// of FP signaling, per domain).
///
/// Moved from WikiCtlCore to WikiFSCore so both `wikictl` and the `wikid` daemon
/// can post change notifications without depending on WikiCtlCore.
public enum DarwinNotifier {
    public static func postChange(forWikiID id: String) {
        #if os(macOS)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(WikiChangeNotification.name(forWikiID: id) as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
        #else
        // Darwin notifications are macOS-only; on Linux the cross-process
        // change-notification path is unused.
        #endif
    }
}
