import Foundation
import WikiFSCore

/// Resolves the `--wiki <id>` / `WIKI_DB` selector to a concrete wiki's
/// `<ulid>.sqlite` path, through the SAME registry the app uses
/// (`plans/llm-wiki.md` — "Takes `--wiki <id>` … resolved through the same
/// registry the app uses").
///
/// Accepts either the wiki's ULID directly, or — for convenience — a display
/// name, which it resolves to the id via the registry. The ULID is tried first
/// so an exactly-matching id is never shadowed by a same-named wiki.
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

    /// Resolve a `--wiki` selector to its descriptor. Returns nil if no wiki in
    /// the registry matches the selector by id or by display name.
    public func descriptor(forSelector selector: String) -> WikiDescriptor? {
        let registry = WikiRegistry.load(from: containerDirectory)
        if let byID = registry.descriptor(id: WikiID(rawValue: selector)) {
            return byID
        }
        return registry.wikis.first { $0.displayName == selector }
    }

    /// The on-disk `<ulid>.sqlite` URL for a resolved descriptor.
    public func databaseURL(for descriptor: WikiDescriptor) -> URL {
        containerDirectory.appendingPathComponent(descriptor.dbFileName, isDirectory: false)
    }
}
