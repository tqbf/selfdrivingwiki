import Foundation
import WikiFSCore

/// Locates the App Group container `wikictl` shares with the app. Since the
/// fixture-binary split (plans/cli-domain-commands.md §"The fixture binary")
/// this is the resolver's ONLY job: there is no wiki resolution here at all —
/// a registry selection (`--wiki`) resolves through the daemon's registry over
/// the socket (`DaemonCommandRouter` → `resolveWiki`), and an explicit
/// database selection does not exist on `wikictl` (the build-only
/// `wikictl-fixture` binary owns that machinery in its own target).
public struct WikiResolver {
    public let containerDirectory: URL

    public init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
    }

    /// The App Group container the un-sandboxed app writes to, built from the
    /// literal home-relative path (`DatabaseLocation.appGroupContainerDirectory`)
    /// so `wikictl` opens the exact same files without an entitlement.
    public static func appGroupContainer() throws -> WikiResolver {
        WikiResolver(containerDirectory: try DatabaseLocation.appGroupContainerDirectory())
    }
}
