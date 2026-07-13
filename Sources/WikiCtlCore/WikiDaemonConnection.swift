import Foundation
import WikiFSCore

/// Errors from the daemon XPC client.
public enum WikiDaemonError: Error, LocalizedError {
    case connectionFailed
    case unexpectedReply

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not connect to the wikid daemon. Is it running? (make install-daemon)"
        case .unexpectedReply:
            return "The wikid daemon returned an unexpected reply."
        }
    }
}

/// Thin XPC client for the `wikid` daemon. Connects via the mach service name
/// registered with launchd; `NSXPCConnection` auto-launches the daemon on first
/// use when it's installed as a LaunchAgent.
///
/// `WikiDescriptor` values are serialized to JSON `Data` for transport (XPC
/// `@objc` protocols require `NSSecureCoding`-compatible types; `Data` bridges
/// to `NSData`).
///
/// See `plans/multi-wiki-daemon.md` §5.2.
public final class WikiDaemonConnection {

    /// The mach service name — must match the launchd plist `Label` and
    /// `MachServices` key.
    public static let serviceName = "com.selfdrivingwiki.wikid"

    private let connection: NSXPCConnection
    private var proxy: WikiDaemonProtocol { connection.remoteObjectProxy as! WikiDaemonProtocol }

    private init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Connect to the daemon. The connection auto-launches via launchd if the
    /// daemon isn't running.
    public static func connect() throws -> WikiDaemonConnection {
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        connection.resume()
        return WikiDaemonConnection(connection: connection)
    }

    // MARK: - Registry

    /// List all wikis, MRU-ordered.
    public func listWikis() async throws -> [WikiDescriptor] {
        try await withCheckedThrowingContinuation { cont in
            proxy.listWikis { data in
                if let wikis = try? JSONDecoder().decode([WikiDescriptor].self, from: data) {
                    cont.resume(returning: wikis)
                } else {
                    cont.resume(throwing: WikiDaemonError.unexpectedReply)
                }
            }
        }
    }

    /// Create a new wiki. Returns the descriptor on success.
    public func createWiki(name: String) async throws -> WikiDescriptor {
        try await withCheckedThrowingContinuation { cont in
            proxy.createWiki(name: name) { data in
                guard let data else {
                    cont.resume(throwing: WikiDaemonError.unexpectedReply)
                    return
                }
                if let descriptor = try? JSONDecoder().decode(WikiDescriptor.self, from: data) {
                    cont.resume(returning: descriptor)
                } else {
                    cont.resume(throwing: WikiDaemonError.unexpectedReply)
                }
            }
        }
    }

    /// Delete a wiki by ID.
    public func deleteWiki(id: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            proxy.deleteWiki(id: id) { success in
                cont.resume(returning: success)
            }
        }
    }

    /// Rename a wiki (display name only).
    public func renameWiki(id: String, name: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            proxy.renameWiki(id: id, name: name) { success in
                cont.resume(returning: success)
            }
        }
    }

    /// Resolve a selector (ULID id or display name) to a descriptor.
    public func resolveWiki(selector: String) async throws -> WikiDescriptor? {
        try await withCheckedThrowingContinuation { cont in
            proxy.resolveWiki(selector: selector) { data in
                guard let data else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: try? JSONDecoder().decode(WikiDescriptor.self, from: data))
            }
        }
    }

    // MARK: - Store lifecycle

    /// Open (or confirm open) the store for a wiki.
    public func openStore(wikiID: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            proxy.openStore(wikiID: wikiID) { success in
                cont.resume(returning: success)
            }
        }
    }

    /// Close the daemon's held-open store for a wiki.
    public func closeStore(wikiID: String) async {
        await withCheckedContinuation { cont in
            proxy.closeStore(wikiID: wikiID) {
                cont.resume()
            }
        }
    }

    /// The current changeToken for a wiki.
    public func changeToken(wikiID: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            proxy.changeToken(wikiID: wikiID) { token in
                cont.resume(returning: token)
            }
        }
    }
}
