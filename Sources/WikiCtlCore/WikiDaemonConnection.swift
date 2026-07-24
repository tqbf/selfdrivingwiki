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

/// Thread-safe single-resume wrapper for a `CheckedContinuation`. The first
/// call to ``resume(_:_:)`` wins; subsequent calls are no-ops.
///
/// Used by ``WikiDaemonConnection.healthCheck(timeout:)`` where the XPC reply,
/// the XPC error handler, and a timeout can all race — only the first should
/// resume the continuation. Internal `NSLock` makes it genuinely thread-safe,
/// justifying `@unchecked Sendable`.
private final class HealthCheckResumeBox: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func resume(_ value: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
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
    /// Three outcomes race: the XPC reply (success), the XPC error handler
    /// (dead/invalidated connection), and a timeout (daemon hung or not
    /// registered with launchd). The first to fire resumes a single
    /// continuation; the others are no-ops via `HealthCheckResumeBox`.
    ///
    /// This must NOT use a `TaskGroup`: a task group waits for ALL child tasks
    /// to complete, and the XPC call task may never complete when the mach
    /// service isn't registered (neither the reply nor the error handler fires).
    /// That would hang the entire method past the timeout — a real bug that
    /// caused the health ping loop and `healthCheckTimeoutParameterIsRespected`
    /// to stall for ~128 s on systems without a daemon (#884).
    public func healthCheck(timeout: TimeInterval = 5) async -> Bool {
        let box = HealthCheckResumeBox()

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Timeout — fires if the daemon never responds (no LaunchAgent
            // registered, or a half-open connection). This is what guarantees
            // the method always returns within `timeout`.
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(false, cont)
            }

            // XPC error handler — fires if the connection is dead/invalidated.
            let proxy = self.connection.remoteObjectProxyWithErrorHandler { _ in
                box.resume(false, cont)
            }
            guard let daemon = proxy as? WikiDaemonProtocol else {
                box.resume(false, cont)
                return
            }
            // XPC reply — fires if the daemon responds.
            daemon.queueSnapshot { _ in
                box.resume(true, cont)
            }
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
