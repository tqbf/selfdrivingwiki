#if os(macOS)
import Foundation
import WikiDaemonGRPC
import WikiDaemonGRPCContract
import WikiFSCore

/// The daemon-side mapping between the registry's domain values and the
/// wire messages. Kept at the boundary (the provider stays domain-free);
/// every field is explicit — no opaque JSON through the gRPC surface.
///
/// ID namespaces (AGENTS.md modeling rules): `AppDaemonWikiId` ↔ `WikiID`,
/// `AppDaemonPageId` ↔ `PageID`. A page id is never passed through a wiki
/// wrapper, in either direction.
enum GRPCRegistryMapping {

    /// Decode the daemon's JSON registry snapshot into the wire reply,
    /// preserving the MRU order.
    static func listWikisReply(fromJSON data: Data) throws -> AppDaemonListWikisReply {
        let descriptors = try JSONDecoder().decode([WikiDescriptor].self, from: data)
        return AppDaemonListWikisReply.with {
            $0.wikis = descriptors.map(descriptor)
        }
    }

    /// Domain descriptor → wire message. `homePageID` uses explicit presence
    /// (`hasHomePageID` on the other side — never an empty-id sentinel).
    static func descriptor(_ value: WikiDescriptor) -> AppDaemonWikiDescriptor {
        AppDaemonWikiDescriptor.with {
            $0.id = AppDaemonWikiId.with { $0.value = value.id.rawValue }
            $0.displayName = value.displayName
            $0.createdAt = .init(date: value.createdAt)
            $0.lastUsedAt = .init(date: value.lastUsedAt)
            if let homePageID = value.homePageID {
                $0.homePageID = AppDaemonPageId.with { $0.value = homePageID.rawValue }
            }
        }
    }

    /// Wire message → domain descriptor (the fixture-server decode path).
    /// Required-field presence is checked via `hasX`, never defaulted: a
    /// missing id or timestamp is a typed invalidRequest, not a silent
    /// empty value.
    static func descriptor(_ value: AppDaemonWikiDescriptor) throws -> WikiDescriptor {
        let rawID = value.id.value
        guard !rawID.isEmpty else {
            throw AppDaemonFailure(
                code: .invalidRequest, message: "WikiDescriptor has no usable id")
        }
        guard value.hasCreatedAt, value.hasLastUsedAt else {
            throw AppDaemonFailure(
                code: .invalidRequest, message: "WikiDescriptor is missing timestamps")
        }
        return WikiDescriptor(
            id: WikiID(rawValue: rawID),
            displayName: value.displayName,
            createdAt: value.createdAt.date,
            lastUsedAt: value.lastUsedAt.date,
            homePageID: value.hasHomePageID
                ? PageID(rawValue: value.homePageID.value)
                : nil)
    }
}
#endif
