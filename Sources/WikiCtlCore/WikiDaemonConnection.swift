#if os(macOS)
import Foundation
import WikiFSCore

/// Connection states for the wikid daemon. Drives the menu-bar icon badge
/// and the in-app disconnected/reconnected banner. All transitions are logged
/// via `DebugLog.store`. See `plans/daemon-health.md` (#878).
public enum DaemonConnectionState: String, Sendable, Equatable {
    /// The daemon responded to the last health probe (or the initial connect).
    case connected
    /// The daemon is unreachable — either the XPC connection was invalidated
    /// (daemon died) or a health ping failed. The app falls back to a local
    /// `QueueEngine`.
    case disconnected
    /// A reconnect attempt is in flight (between a failed probe and the next
    /// one). The app is still on the local fallback.
    case reconnecting
}

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

/// Thin XPC client for the `wikid` daemon. Connects via the XPC service name
/// (resolves to `Contents/XPCServices/wikid.xpc` in the app bundle);
/// `NSXPCConnection` auto-launches the XPC service on first use — no
/// LaunchAgent, no launchctl.
///
/// `WikiDescriptor` values are serialized to JSON `Data` for transport (XPC
/// `@objc` protocols require `NSSecureCoding`-compatible types; `Data` bridges
/// to `NSData`).
///
/// See `plans/multi-wiki-daemon.md` §5.2.
///
/// `@unchecked Sendable`: `NSXPCConnection` is thread-safe for proxy access
/// (Apple's XPC APIs are designed for concurrent use), and `connection` is an
/// immutable `let`. This mirrors `DaemonWorkloadClient`'s conformance.
public final class WikiDaemonConnection: @unchecked Sendable {

    /// The XPC service name — must match the `CFBundleIdentifier` in the
    /// wikid.xpc Info.plist.
    public static let serviceName = "com.selfdrivingwiki.wikid"

    private let connection: NSXPCConnection

    /// Returns the daemon proxy, or throws if the underlying `NSXPCConnection`
    /// couldn't vend a conforming `WikiDaemonProtocol` (e.g. the connection was
    /// invalidated). Replaces the former `as!` force-cast, which trapped on a
    /// dead connection instead of surfacing a catchable error (#878 LOW).
    internal func daemonProxy() throws -> WikiDaemonProtocol {
        guard let p = connection.remoteObjectProxy as? WikiDaemonProtocol else {
            throw WikiDaemonError.connectionFailed
        }
        return p
    }

    private init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Connect to the daemon XPC service. The system launches the XPC service
    /// (from `Contents/XPCServices/wikid.xpc`) on-demand when the first message
    /// is sent — no LaunchAgent plist or launchctl required.
    ///
    /// The `WikiDaemonProtocol` interface is set up with the
    /// `WikiDaemonEventSink` sub-interface on the `registerEventSink(_:)`
    /// selector, so XPC creates a proxy for the sink parameter (bidirectional
    /// XPC) rather than trying to serialize it.
    public static func connect() throws -> WikiDaemonConnection {
        let connection = NSXPCConnection(serviceName: serviceName)
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.resume()
        return WikiDaemonConnection(connection: connection)
    }

    // MARK: - Health & invalidation (#878)

    /// Probe the daemon with a real XPC message (a lightweight `queueSnapshot`
    /// read). Returns `true` if the daemon responded within `timeout`, `false`
    /// if the connection was invalidated, the proxy couldn't be obtained, or the
    /// call timed out.
    ///
    /// Uses `remoteObjectProxyWithErrorHandler` so a dead/invalidated connection
    /// routes to the error handler rather than hanging. The result is
    /// coordinated through a `CheckedContinuation` (thread-safe by design — no
    /// shared mutable outcome variable, fixing the data race flagged in #878
    /// MEDIUM 1).
    ///
    /// A `withThrowingTaskGroup`-based timeout ensures the method always returns
    /// even if neither the reply nor the error handler ever fires (a hung
    /// daemon).
    public func healthCheck(timeout: TimeInterval = 5) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    let proxy = self.connection.remoteObjectProxyWithErrorHandler { _ in
                        cont.resume(returning: false)
                    }
                    guard let daemon = proxy as? WikiDaemonProtocol else {
                        cont.resume(returning: false)
                        return
                    }
                    daemon.queueSnapshot { _ in
                        cont.resume(returning: true)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Install an invalidation handler on the underlying `NSXPCConnection`.
    /// Fires when the daemon process exits (crash, quit, launchd unload) — the
    /// app uses this to swap to a local `QueueEngine` and surface the
    /// disconnected state in the UI (#878 BLOCKER 1.4 + MEDIUM 2).
    ///
    /// Only one handler may be set per connection (XPC replaces the prior one).
    /// The handler is `@Sendable` (fires on an XPC-internal queue); callers that
    /// need main-actor isolation must hop themselves.
    public func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        connection.invalidationHandler = handler
    }

    /// Invalidate the connection explicitly (e.g. before building a new one
    /// for a reconnect attempt).
    public func invalidate() {
        connection.invalidate()
    }

    // MARK: - Registry

    /// List all wikis, MRU-ordered.
    public func listWikis() async throws -> [WikiDescriptor] {
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
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
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
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
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.deleteWiki(id: id) { success in
                cont.resume(returning: success)
            }
        }
    }

    /// Rename a wiki (display name only).
    public func renameWiki(id: String, name: String) async throws -> Bool {
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.renameWiki(id: id, name: name) { success in
                cont.resume(returning: success)
            }
        }
    }

    /// Resolve a selector (ULID id or display name) to a descriptor.
    public func resolveWiki(selector: String) async throws -> WikiDescriptor? {
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
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
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.openStore(wikiID: wikiID) { success in
                cont.resume(returning: success)
            }
        }
    }

    /// Close the daemon's held-open store for a wiki.
    public func closeStore(wikiID: String) async {
        guard let proxy = try? daemonProxy() else { return }
        await withCheckedContinuation { cont in
            proxy.closeStore(wikiID: wikiID) {
                cont.resume()
            }
        }
    }

    /// The current changeToken for a wiki.
    public func changeToken(wikiID: String) async throws -> String {
        let proxy = try daemonProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.changeToken(wikiID: wikiID) { token in
                cont.resume(returning: token)
            }
        }
    }
}
#endif
