import Foundation

/// Posts the wiki-change Darwin notification after a committing write (wikictl
/// or the daemon), so the app's change bridge can refresh the sidebar and signal
/// the File Provider.
///
/// The post is a stable, payload-free "something changed" signal
/// (`WikiChangeNotification.baseName`) and takes NO wiki id: Darwin
/// notifications carry no payload, and encoding the id in the name required the
/// app to pre-subscribe per wiki — which is exactly what made a wiki created
/// while the app runs inaudible (#1374). The consumer re-reads the registry to
/// learn which wikis exist, the same rule
/// `postAgentProvidersConfigChange` / `postExtractorCatalogChange` follow.
///
/// The poster posts ONLY this — it never signals the File Provider itself; that
/// stays the app's job (single owner of FP signaling, per domain).
///
/// Moved from WikiCtlCore to WikiFSCore so both `wikictl` and the `wikid` daemon
/// can post change notifications without depending on WikiCtlCore.
public enum DarwinNotifier {
    public static func postChange() {
        #if os(macOS)
        post(name: WikiChangeNotification.baseName)
        #else
        // Darwin notifications are macOS-only; on Linux the cross-process
        // change-notification path is unused.
        #endif
    }

    public static func postRendererWikiWake(forWikiID id: WikiID) {
        #if os(macOS)
        post(name: RendererChangeNotification.wikiName(forWikiID: id))
        #endif
    }

    public static func postRendererMachineWake(for scopeID: RendererMachineScopeID) {
        #if os(macOS)
        post(name: RendererChangeNotification.machineName(for: scopeID))
        #endif
    }

    /// Posts the stable, payload-free notification for a committed agent-provider
    /// sidecar mutation. Consumers reload the sidecar to obtain its generation.
    public static func postAgentProvidersConfigChange() {
        #if os(macOS)
        post(name: AgentProvidersConfigStore.darwinNotificationName)
        #endif
    }

    /// Posts the stable, payload-free notification for a published extractor
    /// package catalog generation. Consumers reread the authoritative catalog
    /// to learn the generation; the wake never carries package data.
    public static func postExtractorCatalogChange() {
        #if os(macOS)
        post(name: ExtractorCatalogChangeNotification.darwinName)
        #endif
    }

    #if os(macOS)
    private static func post(name rawName: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(rawName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }
    #endif
}
