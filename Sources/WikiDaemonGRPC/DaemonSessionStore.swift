#if os(macOS)
import Foundation

/// One admitted gRPC session: issued over XPC, bound to the issuing XPC
/// connection AND this daemon instance.
///
/// Credentials are opaque random 256-bit values, live only in this process's
/// memory, and are NEVER logged. Admission, exchange, and revocation are
/// serialized through this store (one NSLock; no I/O under the lock).
///
/// Exchange idempotency (plans/app-daemon-wire-contract.md): the same
/// unexpired bootstrap credential exchanges to the SAME session bearer on
/// every call — a dropped reply can be retried within the bootstrap window
/// without creating a second session. After the window expires the XPC side
/// issues a fresh bootstrap for the same live session.
// Every mutable member is covered by `lock` (bootstraps, sessions,
// sessionsByConnection, streams); credentials are never logged.
// swiftlint:disable:next unchecked_sendable
public final class DaemonSessionStore: @unchecked Sendable {

    /// Bootstrap credentials live this long, in nanoseconds of monotonic
    /// uptime. One place to tune; documented in the contract README.
    public static let bootstrapLifetimeNanoseconds: UInt64 = 30_000_000_000

    /// Random instance identifier for this daemon process. A client that
    /// authenticated against a different instance id treats its session as
    /// invalid (instance restart = session death; there is no persistence).
    public let daemonInstanceID: String

    /// The monotonic "now" in uptime nanoseconds. Injectable so tests can
    /// walk expiry forward without sleeping.
    private let now: @Sendable () -> UInt64

    /// The credential generator. Injectable for deterministic tests;
    /// production uses 32 random bytes, hex-encoded.
    private let credentialGenerator: @Sendable () -> String

    private let lock = NSLock()
    private var bootstraps: [String: BootstrapRecord] = [:]
    private var sessions: [String: SessionRecord] = [:]
    /// XPC connection id → session bearer hex. One logical session per
    /// admitted XPC connection: a second bootstrap for the same connection
    /// resolves to the SAME session (repeated admission never forks a
    /// session).
    private var sessionsByConnection: [String: String] = [:]
    /// Live server-streaming subscriptions, terminated on revocation.
    private var streams: [String: [UUID: any SessionStreamHandle]] = [:]

    struct BootstrapRecord {
        let sessionHex: String
        let expiresAtUptimeNS: UInt64
    }

    struct SessionRecord {
        let connectionID: String
    }

    /// The admission offer the daemon hands back over XPC (JSON, never gRPC):
    /// where the endpoint is and which bootstrap credential admits it.
    public struct AdmissionOffer: Equatable, Sendable {
        public let socketPath: String
        public let bootstrapCredentialHex: String
        public let daemonInstanceID: String
        /// Absolute expiry, computed from the injected monotonic clock, for
        /// diagnostics and client back-off decisions. The store itself only
        /// compares uptime.
        public let expiresAt: Date

        public init(
            socketPath: String, bootstrapCredentialHex: String,
            daemonInstanceID: String, expiresAt: Date
        ) {
            self.socketPath = socketPath
            self.bootstrapCredentialHex = bootstrapCredentialHex
            self.daemonInstanceID = daemonInstanceID
            self.expiresAt = expiresAt
        }
    }

    /// Per-call server-side session identity, returned by ``validate``.
    public struct SessionContext: Equatable, Sendable {
        public let credentialHex: String
        /// The issuing XPC connection's stable id. Workload handlers key
        /// staging cleanup and stream ownership on this.
        public let connectionID: String

        public init(credentialHex: String, connectionID: String) {
            self.credentialHex = credentialHex
            self.connectionID = connectionID
        }
    }

    /// A live server-streaming RPC registered against a session. Revocation
    /// calls ``terminate`` once; the handle is then dead. The handle owns its
    /// id before registration so revocation can never miss a stream.
    public protocol SessionStreamHandle: AnyObject, Sendable {
        /// The stable registration id (minted by the handle itself).
        var id: UUID { get }
        /// End the stream server-side (revocation or shutdown). Idempotent.
        /// AsyncStream vocabulary deliberately: this ends an in-process
        /// subscription, nothing process-shaped.
        func finish()
    }

    // MARK: - Init

    /// - Parameters:
    ///   - now: monotonic uptime in nanoseconds (injectable for tests).
    ///   - credentialGenerator: opaque credential source (injectable for
    ///     deterministic tests; production randomizes 256 bits).
    public init(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        credentialGenerator: @escaping @Sendable () -> String = {
            (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }
                .joined()
        }
    ) {
        self.now = now
        self.credentialGenerator = credentialGenerator
        self.daemonInstanceID = UUID().uuidString
    }

    // MARK: - XPC side (admission)

    /// Fixture seam through the production issuer (the contract's test-only
    /// issuance seam): seed a fixed bootstrap→session binding so an interop
    /// peer can send the corpus's bootstrap credential. Never used by the
    /// XPC admission path itself.
    public func seedBootstrapForFixtures(
        bootstrapHex: String, sessionHex: String, connectionID: String
    ) {
        let uptimeNow = now()
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionHex] = SessionRecord(connectionID: connectionID)
        sessionsByConnection[connectionID] = sessionHex
        bootstraps[bootstrapHex] = BootstrapRecord(
            sessionHex: sessionHex,
            expiresAtUptimeNS: uptimeNow + Self.bootstrapLifetimeNanoseconds)
    }

    /// Issue the bootstrap credential for an admitted XPC connection.
    ///
    /// One logical session per connection: the FIRST call creates the session
    /// and mints its bootstrap; REPEATED calls return a bootstrap for the
    /// SAME session (a fresh 30 s window after the old one expired — this is
    /// the recovery path for a dropped exchange reply). A second session for
    /// one connection is never created.
    public func admissionOffer(
        socketPath: String, connectionID: String
    ) -> AdmissionOffer {
        let credential = credentialGenerator()
        let uptimeNow = now()
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(uptimeNow: uptimeNow)

        let sessionHex: String
        if let existing = sessionsByConnection[connectionID], sessions[existing] != nil {
            sessionHex = existing
        } else {
            sessionHex = credentialGenerator()
            sessions[sessionHex] = SessionRecord(connectionID: connectionID)
            sessionsByConnection[connectionID] = sessionHex
        }
        bootstraps[credential] = BootstrapRecord(
            sessionHex: sessionHex,
            expiresAtUptimeNS: uptimeNow + Self.bootstrapLifetimeNanoseconds)
        let expiresAt = Date().addingTimeInterval(
            Double(Self.bootstrapLifetimeNanoseconds) / 1_000_000_000)
        return AdmissionOffer(
            socketPath: socketPath,
            bootstrapCredentialHex: credential,
            daemonInstanceID: daemonInstanceID,
            expiresAt: expiresAt)
    }

    /// Exchange a bootstrap credential for its session bearer. Returns nil
    /// for unknown, expired, or already-swept bootstraps. Idempotent within
    /// the window: the same bootstrap always returns the same bearer.
    public func exchange(bootstrapHex: String) -> String? {
        let uptimeNow = now()
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(uptimeNow: uptimeNow)
        guard let record = bootstraps[bootstrapHex] else { return nil }
        guard sessions[record.sessionHex] != nil else { return nil }
        return record.sessionHex
    }

    // MARK: - gRPC server side

    /// Validate a bearer credential from `authorization` metadata. Returns
    /// nil (→ typed UNAUTHENTICATED before any workload dispatch) for
    /// missing, unknown, revoked, or prior-instance credentials.
    public func validate(bearerHex: String) -> SessionContext? {
        let uptimeNow = now()
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(uptimeNow: uptimeNow)
        guard let record = sessions[bearerHex] else { return nil }
        return SessionContext(credentialHex: bearerHex, connectionID: record.connectionID)
    }

    /// Register a live streaming subscription under a session, keyed by the
    /// handle's own id. The handle is terminated when the session is revoked
    /// or the store shuts down.
    public func registerStream(sessionHex: String, _ handle: any SessionStreamHandle) {
        lock.lock()
        defer { lock.unlock() }
        streams[sessionHex, default: [:]][handle.id] = handle
    }

    /// Drop a stream registration without terminating it (clean client-side
    /// end of the RPC).
    public func unregisterStream(sessionHex: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        streams[sessionHex]?.removeValue(forKey: id)
        if streams[sessionHex]?.isEmpty == true { streams.removeValue(forKey: sessionHex) }
    }

    /// Revoke the session bound to an XPC connection. IDEMPOTENT. Order per
    /// the contract: the session dies first (no new calls, no staging
    /// changes admitted), then every live stream is terminated. Never logs
    /// credentials.
    @discardableResult
    public func revokeSession(connectionID: String) -> Bool {
        var handles: [any SessionStreamHandle] = []
        lock.lock()
        guard let sessionHex = sessionsByConnection[connectionID] else {
            lock.unlock()
            return false
        }
        sessions.removeValue(forKey: sessionHex)
        sessionsByConnection.removeValue(forKey: connectionID)
        for (bootstrapHex, record) in bootstraps where record.sessionHex == sessionHex {
            bootstraps.removeValue(forKey: bootstrapHex)
        }
        handles = Array(streams[sessionHex]?.values ?? [:].values)
        streams.removeValue(forKey: sessionHex)
        lock.unlock()

        for handle in handles { handle.finish() }
        return true
    }

    /// Revoke every live session (daemon shutdown). Terminates all streams.
    public func revokeAll() {
        var handles: [any SessionStreamHandle] = []
        lock.lock()
        handles = streams.values.flatMap { $0.values }
        streams.removeAll()
        sessions.removeAll()
        sessionsByConnection.removeAll()
        bootstraps.removeAll()
        lock.unlock()
        for handle in handles { handle.finish() }
    }

    // MARK: - Internals

    /// Lazy expiry sweep. Called under `lock`.
    private func sweepExpiredLocked(uptimeNow: UInt64) {
        bootstraps = bootstraps.filter { $0.value.expiresAtUptimeNS > uptimeNow }
    }
}
#endif
