import Foundation
import WikiFSCore

/// Errors from the daemon XPC client.
public enum WikiDaemonError: Error, LocalizedError {
    case connectionFailed
    case unexpectedReply
    case timeout
    case interrupted
    case invalidated

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Could not connect to the wikid daemon. Is it running? (make install-daemon)"
        case .unexpectedReply:
            return "The wikid daemon returned an unexpected reply."
        case .timeout:
            return "The wikid daemon did not respond within the timeout (the daemon may be restarting)."
        case .interrupted:
            return "The connection to the wikid daemon was interrupted (the daemon may be restarting)."
        case .invalidated:
            return "The connection to the wikid daemon was invalidated (the daemon may have crashed)."
        }
    }
}

/// Thin XPC client for the `wikid` daemon. Connects via the mach service name
/// registered with launchd; `NSXPCConnection` auto-launches the daemon on first
/// use when it's installed as a LaunchAgent.
///
/// **Crash recovery:** every XPC call is wrapped in a timeout + interruption /
/// invalidation handlers so the client never hangs forever if the daemon is
/// dead or restarting. Callers (`wikictl`) fall back to direct file access when
/// the daemon is unavailable — this makes the timeout fast (default 5s).
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

    /// Default timeout for XPC calls (seconds). 15s is generous enough for
    /// launchd's cold-start + the daemon's SQLite bootstrap; still fails fast
    /// enough that the CLI doesn't feel hung when the daemon is truly gone.
    private static let defaultTimeout: UInt64 = 15

    private let connection: NSXPCConnection

    /// Set when the connection is interrupted (daemon crashed/restarting).
    /// Used to fail pending calls immediately rather than waiting for timeout.
    private var isInterrupted = false

    /// Set when the connection is invalidated (daemon is gone and won't come back).
    private var isInvalidated = false

    private init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Connect to the daemon. The connection auto-launches via launchd if the
    /// daemon isn't running (when installed as a LaunchAgent). Sets
    /// interruption + invalidation handlers so pending calls fail fast instead
    /// of hanging until the timeout.
    public static func connect() throws -> WikiDaemonConnection {
        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let wrapper = WikiDaemonConnection(connection: connection)
        wrapper.setupHandlers()
        connection.resume()
        return wrapper
    }

    /// Wire interruption + invalidation handlers so pending calls fail fast
    /// instead of hanging until the timeout.
    private func setupHandlers() {
        connection.interruptionHandler = { [weak self] in
            self?.isInterrupted = true
        }
        connection.invalidationHandler = { [weak self] in
            self?.isInvalidated = true
        }
    }

    // MARK: - Call wrapper with timeout + interruption handling

    /// Wraps an XPC reply-closure call in a timeout + interruption check.
    /// If the daemon is interrupted or the call doesn't complete within
    /// `defaultTimeout` seconds, throws `WikiDaemonError.timeout`.
    private func callWithTimeout<T: Sendable>(_ body: (@escaping (T) -> Void) -> Void) async throws -> T {
        // Fail fast if the connection is already known-broken.
        if isInvalidated { throw WikiDaemonError.invalidated }
        if isInterrupted { throw WikiDaemonError.interrupted }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let box = ContinuationBox<T>(cont: cont)

            // The actual XPC call.
            body { value in
                box.resumeOnce(.success(value))
            }

            // Timeout watchdog. Runs on a background queue so it doesn't
            // block the main thread (important for wikictl's `await`).
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(Self.defaultTimeout))) {
                box.resumeOnce(.failure(WikiDaemonError.timeout))
            }
        }
    }

    /// Same as `callWithTimeout` but for calls that return `T?` (nil = failure).
    private func callWithTimeoutOptional<T: Sendable>(_ body: (@escaping (T?) -> Void) -> Void) async throws -> T? {
        if isInvalidated { throw WikiDaemonError.invalidated }
        if isInterrupted { throw WikiDaemonError.interrupted }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T?, Error>) in
            let box = ContinuationBox<T?>(cont: cont)

            body { value in
                box.resumeOnce(.success(value))
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(Self.defaultTimeout))) {
                box.resumeOnce(.failure(WikiDaemonError.timeout))
            }
        }
    }

    private var proxy: WikiDaemonProtocol {
        connection.remoteObjectProxy as! WikiDaemonProtocol
    }

    // MARK: - Registry

    /// List all wikis, MRU-ordered.
    public func listWikis() async throws -> [WikiDescriptor] {
        let data: Data = try await callWithTimeout { completion in
            self.proxy.listWikis { data in
                completion(data)
            }
        }
        guard let wikis = try? JSONDecoder().decode([WikiDescriptor].self, from: data) else {
            throw WikiDaemonError.unexpectedReply
        }
        return wikis
    }

    /// Create a new wiki. Returns the descriptor on success.
    public func createWiki(name: String) async throws -> WikiDescriptor {
        let data = try await callWithTimeoutOptional { completion in
            self.proxy.createWiki(name: name) { data in
                completion(data)
            }
        }
        guard let data else {
            throw WikiDaemonError.unexpectedReply
        }
        guard let descriptor = try? JSONDecoder().decode(WikiDescriptor.self, from: data) else {
            throw WikiDaemonError.unexpectedReply
        }
        return descriptor
    }

    /// Delete a wiki by ID.
    public func deleteWiki(id: String) async throws -> Bool {
        try await callWithTimeout { completion in
            self.proxy.deleteWiki(id: id) { success in
                completion(success)
            }
        }
    }

    /// Rename a wiki (display name only).
    public func renameWiki(id: String, name: String) async throws -> Bool {
        try await callWithTimeout { completion in
            self.proxy.renameWiki(id: id, name: name) { success in
                completion(success)
            }
        }
    }

    /// Resolve a selector (ULID id or display name) to a descriptor.
    public func resolveWiki(selector: String) async throws -> WikiDescriptor? {
        let data = try await callWithTimeoutOptional { completion in
            self.proxy.resolveWiki(selector: selector) { data in
                completion(data)
            }
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(WikiDescriptor.self, from: data)
    }

    // MARK: - Store lifecycle

    /// Open (or confirm open) the store for a wiki.
    public func openStore(wikiID: String) async throws -> Bool {
        try await callWithTimeout { completion in
            self.proxy.openStore(wikiID: wikiID) { success in
                completion(success)
            }
        }
    }

    /// Close the daemon's held-open store for a wiki.
    public func closeStore(wikiID: String) async {
        // Best-effort — don't throw on close.
        _ = try? await callWithTimeout { (completion: @escaping (Bool) -> Void) in
            self.proxy.closeStore(wikiID: wikiID) {
                completion(true)
            }
        }
    }

    /// The current changeToken for a wiki.
    public func changeToken(wikiID: String) async throws -> String {
        try await callWithTimeout { completion in
            self.proxy.changeToken(wikiID: wikiID) { token in
                completion(token)
            }
        }
    }
}

/// Lock-guarded, single-shot continuation wrapper. Race-safe: the XPC reply
/// and the timeout watchdog both call `resumeOnce`; whichever fires first
/// wins, the other is a no-op. `@unchecked Sendable` because the lock
/// guarantees the happens-before relationship for the `resumed` flag.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let cont: CheckedContinuation<T, Error>

    init(cont: CheckedContinuation<T, Error>) {
        self.cont = cont
    }

    func resumeOnce(_ result: Result<T, Error>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        switch result {
        case .success(let value): cont.resume(returning: value)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
