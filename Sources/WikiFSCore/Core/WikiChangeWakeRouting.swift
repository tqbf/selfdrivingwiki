import Foundation

/// Resolves a received wiki-change Darwin notification to the wikis the change
/// bridge must refresh.
///
/// This is a pure function so the "which wikis does a payload-free wake fan out
/// to?" decision is unit-testable without Darwin, a File Provider, or the main
/// actor — the app-layer `WikiChangeBridge` only supplies the current wiki set.
///
/// ## Why fan out to every wiki
///
/// The wake is a single payload-free name (`WikiChangeNotification.baseName`),
/// so it does not say which wiki changed — the writer's id cannot travel in it
/// (see that type for the full rationale, and #1374 for the per-wiki scheme this
/// replaced). The receiving side therefore has to decide between two shapes:
///
/// - **Reconcile the observed set, then resolve.** Needs the changed wiki's id
///   to pick one; the wake cannot supply it, so this collapses to guessing.
/// - **Fan out to every wiki the registry currently lists.** Correct by
///   construction: the changed wiki is by definition in the registry, so it is
///   always refreshed. A wiki that is NOT in the registry has no File Provider
///   domain to signal and no session to poke, so skipping it costs nothing.
///
/// Fan-out is the honest reading of a payload-free signal. The cost is bounded
/// by the registry size (a handful of wikis) and each flush is idempotent:
/// `WikiChangeBridge.flush` signals that wiki's File Provider domain and pokes
/// only the live sessions whose `wikiID` matches. The per-wiki `ChangeCoalescer`
/// still collapses a write burst into ONE flush per wiki, so a burst does not
/// multiply by the wiki count.
public enum WikiChangeWakeRouting {
    /// The wikis to refresh for a received notification name, or `nil` when the
    /// name is not a wiki-change wake at all (the bridge shares one callback
    /// with the renderer-machine namespace).
    ///
    /// `knownWikiIDs` is the CURRENT registry — re-read at receipt, not the set
    /// captured at launch — so a wiki created while the app runs is refreshed by
    /// the very next wake.
    public static func wikiIDs(
        forNotificationName name: String,
        knownWikiIDs: [WikiID]
    ) -> [WikiID]? {
        guard name == WikiChangeNotification.baseName else { return nil }
        return knownWikiIDs
    }
}
