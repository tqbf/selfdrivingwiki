#if os(macOS)
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
    internal var proxy: WikiDaemonProtocol { connection.remoteObjectProxy as! WikiDaemonProtocol }

    /// Invoked from the connection's `invalidationHandler` after the daemon
    /// connection breaks (daemon quit / crash). Production leaves this nil —
    /// the handler just logs via `DebugLog`. Tests set it to observe that the
    /// handler actually fires (#878).
    internal var onInvalidation: (() -> Void)?

    private init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Connect to the daemon. The connection auto-launches via launchd if the
    /// daemon isn't running.
    ///
    /// After `resume()`, a **health check** probes the daemon with a trivial
    /// read-only call (`listWikis`) bounded by a timeout. `NSXPCConnection`
    /// is lazy: `resume()` succeeds even when no daemon is listening, so this
    /// probe is what actually verifies a live daemon (#878). If it times out or
    /// the connection errors, `connect()` throws and callers fall back to the
    /// local `QueueEngine` (app) or a direct-file path (`wikictl`).
    ///
    /// The `WikiDaemonProtocol` interface is set up with the
    /// `WikiDaemonEventSink` sub-interface on the `registerEventSink(_:)`
    /// selector, so XPC creates a proxy for the sink parameter (bidirectional
    /// XPC) rather than trying to serialize it. An `invalidationHandler` logs
    /// when the daemon dies mid-session.
    public static func connect() throws -> WikiDaemonConnection {
        try connect(serviceName: serviceName)
    }

    /// Internal overload: target a specific mach service name. Tests point this
    /// at a non-existent service to assert the health check fails when nothing
    /// is listening (#878).
    internal static func connect(
        serviceName: String,
        healthCheckTimeout: TimeInterval = 5
    ) throws -> WikiDaemonConnection {
        try makeAndProbe(
            connection: NSXPCConnection(machServiceName: serviceName),
            timeout: healthCheckTimeout)
    }

    /// Internal overload: connect to an in-process daemon via an anonymous
    /// listener endpoint (no launchd required). Used by tests to exercise a
    /// *healthy* round-trip + invalidation against a real `WikiDaemon`.
    internal static func connect(
        endpoint: NSXPCListenerEndpoint,
        healthCheckTimeout: TimeInterval = 5
    ) throws -> WikiDaemonConnection {
        try makeAndProbe(
            connection: NSXPCConnection(listenerEndpoint: endpoint),
            timeout: healthCheckTimeout)
    }

    /// Shared by every connect path: wrap the connection, configure the XPC
    /// interface + invalidation handler, resume, then probe. On probe failure
    /// the half-open connection is invalidated before throwing so no leak is
    /// left behind.
    private static func makeAndProbe(
        connection: NSXPCConnection,
        timeout: TimeInterval
    ) throws -> WikiDaemonConnection {
        let conn = WikiDaemonConnection(connection: connection)
        conn.configureInterfaceAndInvalidation()
        connection.resume()
        do {
            try conn.healthCheck(timeout: timeout)
        } catch {
            connection.invalidate()
            throw error
        }
        return conn
    }

    /// Apply the daemon interface (with the bidirectional event-sink sub-
    /// interface) and install an `invalidationHandler` that logs when the
    /// daemon connection breaks mid-session, then forwards to ``onInvalidation``
    /// for test observation. `[weak self]` avoids a connection→handler→self
    /// retain cycle.
    private func configureInterfaceAndInvalidation() {
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        connection.remoteObjectInterface = daemonInterface
        connection.invalidationHandler = { [weak self] in
            DebugLog.store("wikid: daemon connection invalidated — XPC calls will fail until restart")
            self?.onInvalidation?()
        }
    }

    /// Verify the daemon is actually responding. `NSXPCConnection` is lazy, so
    /// a successful `resume()` proves nothing — we must exchange a message.
    /// Issues a trivial read-only `listWikis` call through a proxy with an error
    /// handler, bounded by `timeout`. Success ⟺ the daemon replied.
    ///
    /// Bridges the inherently-async XPC reply to this synchronous `connect()`
    /// path via a `DispatchSemaphore` — safe because XPC replies dispatch on an
    /// internal queue, never the calling (main) thread, so there is no
    /// self-deadlock. The timeout is the worst-case ceiling; a missing mach
    /// service errors well inside it.
    private func healthCheck(timeout: TimeInterval) throws {
        var outcome: Result<Void, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        // A fresh proxy carrying an error handler — the stored `proxy` has none,
        // so a broken connection would otherwise hang until the timeout instead
        // of surfacing the connection error.
        let probe = connection.remoteObjectProxyWithErrorHandler { error in
            outcome = .failure(error)
            semaphore.signal()
        } as! WikiDaemonProtocol

        probe.listWikis { _ in
            // The daemon replied — we don't care about the payload, only that
            // it answered. It is alive.
            outcome = .success(())
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw WikiDaemonError.connectionFailed
        }
        try outcome?.get()
    }

    /// Invalidate the underlying connection (test/cleanup seam). Triggers the
    /// `invalidationHandler` installed by ``connect()``.
    internal func invalidate() {
        connection.invalidate()
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
#endif
