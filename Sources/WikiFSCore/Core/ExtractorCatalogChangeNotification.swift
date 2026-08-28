import Foundation

public extension Notification.Name {
    /// Emitted in-process after the extractor package catalog publishes a new
    /// generation. Observers reread the authoritative catalog; the notification
    /// itself carries no generation and no package payload.
    /// Derived from the Darwin name so the in-process and cross-process wake
    /// identities cannot drift apart.
    static let extractorPackageCatalogDidChange = Notification.Name(
        ExtractorCatalogChangeNotification.darwinName
    )
}

/// The stable, payload-free wake name for extractor catalog publication.
///
/// A wake is only an invitation to reread. The durable catalog generation, not
/// the wake, decides what each process applies, so a lost, duplicated, or
/// out-of-order wake cannot produce a wrong process graph.
public enum ExtractorCatalogChangeNotification {
    public static let darwinName = "org.selfdrivingwiki.extractorPackageCatalogDidChange"
}
