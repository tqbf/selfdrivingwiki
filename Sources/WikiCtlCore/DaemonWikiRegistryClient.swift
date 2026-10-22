#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// CLI-side client for the daemon's `wiki` registry family over the local
/// socket (`DaemonDomainSocketClient`, family `.wiki`) — Phase 2 of
/// `plans/cli-domain-commands.md`. Every verb routes to the daemon's
/// EXISTING registry methods, so the daemon stays the single pathway to
/// `wikis.json` and the per-wiki databases:
///
/// - `listWikis` / `resolveWiki` adopt the on-disk registry (the app is the
///   primary writer; app-side creates and renames are visible immediately).
/// - `createWiki` runs the daemon's creation coordinator (bootstrap + seed +
///   child profile + registry persistence) — there is no CLI-side
///   `createAndSeed` anymore.
/// - `deleteWiki` inherits the daemon's FULL eviction (search runtime
///   shutdown, child profile removal, registry row, database artifacts),
///   closing the CLI's degraded-delete race.
///
/// Failure contract: an unknown wiki is a typed `DaemonDomainError` with
/// code `.notFound` and the message `no wiki matching <selector>`; daemon-side
/// failures are `.operationFailed`; the app being closed surfaces as
/// `SearchSocketError.daemonNotRunning` from the transport. No local
/// fallback, ever.
//
// Immutable Sendable value (socket path + timeout).
public struct DaemonWikiRegistryClient: Sendable {

    private let socket: DaemonDomainSocketClient

    public init(
        containerDirectory: URL,
        timeout: TimeInterval = DaemonWorkloadClient.defaultTimeout
    ) throws {
        self.socket = try DaemonDomainSocketClient(
            containerDirectory: containerDirectory,
            timeout: timeout)
    }

    /// All wikis, MRU-ordered (the daemon's registry view). An empty registry
    /// is a valid empty answer, not an error.
    public func listWikis() async throws -> [WikiDescriptor] {
        let reply = try await socket.send(
            family: .wiki,
            operation: DaemonDomainOperation.Wiki.listWikis)
        guard let payload = reply.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "listWikis reply carried no payload")
        }
        do {
            return try JSONDecoder().decode([WikiDescriptor].self, from: payload)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "listWikis payload could not be decoded")
        }
    }

    /// Create a wiki and return its descriptor (Home page already seeded by
    /// the daemon's bootstrap).
    public func createWiki(name: String) async throws -> WikiDescriptor {
        let payload = try JSONEncoder().encode(DaemonWikiCreateRequest(name: name))
        return try await descriptor(
            operation: DaemonDomainOperation.Wiki.createWiki, payload: payload)
    }

    /// Delete a wiki with the daemon's full eviction. Throws `.notFound` for
    /// an unknown id.
    public func deleteWiki(id: WikiID) async throws {
        let payload = try JSONEncoder().encode(DaemonWikiDeleteRequest(id: id.rawValue))
        _ = try await socket.send(
            family: .wiki,
            operation: DaemonDomainOperation.Wiki.deleteWiki,
            payload: payload)
    }

    /// Rename a wiki's display name (identity and database untouched).
    public func renameWiki(id: WikiID, name: String) async throws {
        let payload = try JSONEncoder().encode(
            DaemonWikiRenameRequest(id: id.rawValue, name: name))
        _ = try await socket.send(
            family: .wiki,
            operation: DaemonDomainOperation.Wiki.renameWiki,
            payload: payload)
    }

    /// Resolve a ULID id or display name to its descriptor. Throws `.notFound`
    /// when nothing matches.
    public func resolveWiki(selector: String) async throws -> WikiDescriptor {
        let payload = try JSONEncoder().encode(DaemonWikiResolveRequest(selector: selector))
        return try await descriptor(
            operation: DaemonDomainOperation.Wiki.resolveWiki, payload: payload)
    }

    // MARK: - Shared reply decode

    private func descriptor(
        operation: String,
        payload: Data
    ) async throws -> WikiDescriptor {
        let reply = try await socket.send(family: .wiki, operation: operation, payload: payload)
        guard let data = reply.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(operation) reply carried no payload")
        }
        do {
            return try JSONDecoder().decode(WikiDescriptor.self, from: data)
        } catch {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "\(operation) payload could not be decoded")
        }
    }
}
#endif
