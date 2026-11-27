#if os(macOS)
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import WikiDaemonGRPCContract

/// What the XPC admission call hands the client: where the endpoint is and
/// which short-lived bootstrap credential admits it. JSON over XPC — the
/// credential never crosses the gRPC channel except as `authorization`
/// metadata.
public struct AppDaemonAdmission: Equatable, Sendable, Codable {
    public let socketPath: String
    public let bootstrapCredentialHex: String
    public let daemonInstanceID: String
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

/// The client-side gRPC session for the app–daemon contract.
///
/// Lifecycle (plans/app-daemon-wire-contract.md): connect over the
/// XPC-admitted Unix domain socket → exchange the bootstrap credential once
/// for the session bearer → verify capabilities → workload calls. Every call
/// carries the bearer as `authorization` metadata and an explicit deadline.
/// On XPC interruption the app closes this client and reconnects from a
/// fresh baseline (the server revoked the old session when the connection
/// died). No gRPC-level retries: bootstrap and subscription recovery use
/// the app's bounded backoff; mutations are never retried on ambiguity.
// Session state (`bearerHex`) is covered by `lock`; the client/stub/
// run task are immutable after init.
// swiftlint:disable:next unchecked_sendable
public final class AppDaemonSessionClient: @unchecked Sendable {

    /// Explicit per-call deadlines (contract: every unary call carries one).
    public enum Deadlines {
        /// The bootstrap exchange and the capabilities handshake.
        public static let handshake: Duration = .seconds(10)
        /// Unary workload calls (first slice: ListWikis).
        public static let unary: Duration = .seconds(30)
    }

    /// The declared single-message bound, enforced client-side per call
    /// (mirrors the server transport's 4 MiB default; the contract's bounds
    /// rule — receivers reject oversize with RESOURCE_EXHAUSTED).
    public static let maxMessageBytes = 4 * 1024 * 1024

    /// Capability names required by this client build. The server must serve
    /// every one of them before any workload call.
    public static let requiredCapabilities = ["admission.v1", "registry.v1", "events.v1"]
    public static let requiredContractVersion: UInt32 = 1

    private let admission: AppDaemonAdmission
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let stub: AppDaemonAppDaemon.Client<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Never>

    /// Lock-guarded session state. The bearer + instance id publish
    /// ATOMICALLY, only after the full handshake (exchange + capabilities
    /// verification) succeeds — workload calls can never use an unverified
    /// bearer, and `authenticatedInstanceID` reflects what the handshake
    /// proved. Locking stays out of async contexts — sync helpers only.
    private let lock = NSLock()
    private var session: SessionState?
    /// Terminal closed flag: set by close(); a bootstrap racing close never
    /// publishes, and a subscription racing close is cancelled immediately.
    private var closed = false
    /// Live subscription tasks; close() cancels them (graceful shutdown
    /// alone does not terminate an open server stream).
    private var subscriptionTasks: [Task<Void, Never>] = []

    private struct SessionState {
        let bearerHex: String
        let instanceID: String
    }

    /// The instance id the session authenticated against (nil before the
    /// handshake completed).
    public var authenticatedInstanceID: String? {
        lock.withLock { session?.instanceID }
    }

    public init(admission: AppDaemonAdmission) throws {
        self.admission = admission
        // Plaintext loopback over the private Unix domain socket. The
        // transport default enforces the declared 4 MiB single-message
        // bound; retries/hedging are not negotiated (no service config is
        // exchanged on this socket).
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: admission.socketPath, authority: "localhost"),
            transportSecurity: .plaintext)
        self.client = GRPCClient(transport: transport)
        self.stub = AppDaemonAppDaemon.Client(wrapping: client)
        // GRPCClient only serves calls while its connection loop runs.
        self.runTask = Task { [client] in
            do {
                try await client.runConnections()
            } catch is CancellationError {
                // Normal shutdown path.
            } catch {
                // Transport death surfaces on the next call as a typed
                // failure; nothing actionable here.
            }
        }
    }

    deinit {
        client.beginGracefulShutdown()
    }

    /// End the session client-side (reconnect path). Cancels owned
    /// subscription streams FIRST (graceful shutdown does not terminate an
    /// open server stream), then stops opening new connections.
    public func close() {
        // ONE lock hold sets the terminal flag, snapshots, and clears the
        // task table — a subscription racing close registers into the same
        // critical section and sees `closed`, cancelling itself.
        let tasks: [Task<Void, Never>] = lock.withLock {
            closed = true
            let tasks = subscriptionTasks
            subscriptionTasks = []
            return tasks
        }
        for task in tasks { task.cancel() }
        client.beginGracefulShutdown()
    }

    /// Run the admission exchange + capabilities handshake. Idempotent
    /// within the bootstrap window (the server returns the same bearer), so
    /// a dropped reply can be re-attempted inside the window.
    public func bootstrap() async throws {
        // The candidate bearer + the ADMISSION's instance id stay private
        // until verification passes: workload calls can never use an
        // unverified bearer, and a failed handshake leaves the session
        // state untouched.
        let (candidateBearer, admittedInstanceID) = try await admitSession()

        let capabilities = try await getCapabilities(bearer: candidateBearer)
        try Self.verifyCapabilities(
            capabilities,
            expectedInstance: admission.daemonInstanceID,
            advertisedInstance: capabilities.daemonInstanceID,
            admittedInstance: admittedInstanceID)

        let published: Bool = lock.withLock {
            guard !closed else { return false }
            session = SessionState(
                bearerHex: candidateBearer,
                instanceID: capabilities.daemonInstanceID)
            return true
        }
        guard published else {
            throw AppDaemonFailure(
                code: .unauthenticated, message: "Session was closed during bootstrap")
        }
    }

    /// List the wiki registry (MRU-ordered). The client's authoritative
    /// baseline read for the registry family.
    public func listWikis() async throws -> AppDaemonListWikisReply {
        let bearer = try requireBearerSync()
        return try await withDeadline(Deadlines.unary) { options in
            try await self.stub.listWikis(
                request: ClientRequest(
                    message: AppDaemonListWikisRequest(),
                    metadata: Self.authorization(bearer)),
                options: options)
        }
    }

    /// Subscribe to live registry events. Ends on session revocation (plain
    /// end) or fails typed — `resyncRequired` on overflow/epoch — and the
    /// caller resyncs from authoritative state (``listWikis``) before
    /// resubscribing. Cancel by cancelling the consumer task.
    public func subscribeRegistryEvents() -> AsyncThrowingStream<AppDaemonRegistryEvent, Error> {
        subscribeEvents(families: [.registry])
    }

    /// The family-parameterized subscription (the typed registry adapter
    /// passes `[.registry]`; the contract's rejection of unserved families
    /// is exercised by passing others in tests).
    public func subscribeEvents(
        families: [AppDaemonEventFamily]
    ) -> AsyncThrowingStream<AppDaemonRegistryEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bearer = try self.requireBearerSync()
                    var options = CallOptions.defaults
                    options.timeout = nil // stream lifetime, not per-call
                    _ = try await self.stub.subscribeEvents(
                        request: ClientRequest(
                            message: AppDaemonSubscribeEventsRequest.with {
                                $0.families = families
                            },
                            metadata: Self.authorization(bearer)),
                        options: options) { response in
                            switch response.accepted {
                            case .failure(let rpcError):
                                throw Self.typed(rpcError)
                            case .success(let contents):
                                for try await part in contents.bodyParts {
                                    guard case .message(let event) = part else {
                                        continue
                                    }
                                    // Exhaustive oneof dispatch (semantic
                                    // rule 6): an unknown future variant is
                                    // a typed failure, never a silent drop.
                                    guard let payload = event.event,
                                          case .registry(let registryEvent) = payload
                                    else {
                                        throw AppDaemonFailure(
                                            code: .invalidRequest,
                                            message: "Unknown event variant; "
                                                + "resync from authoritative state")
                                    }
                                    // Unknown numeric KIND (semantic rule 3):
                                    // the receiver must not guess — the typed
                                    // failure sends the caller back to
                                    // authoritative state.
                                    switch registryEvent.kind {
                                    case .created, .renamed, .deleted:
                                        break
                                    // .unspecified or ANY unrecognized numeric
                                    // value: never guess (semantic rules 3/6).
                                    case .unspecified, .UNRECOGNIZED:
                                        throw AppDaemonFailure(
                                            code: .invalidRequest,
                                            message: "Unknown registry event kind; "
                                                + "resync from authoritative state")
                                    }
                                    continuation.yield(registryEvent)
                                }
                            }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.typed(error))
                }
            }
            // Registered so close() cancels this stream (graceful transport
            // shutdown does not terminate an open RPC); if close() already
            // ran, cancel immediately. A finished task stops pinning memory.
            let alreadyClosed = self.lock.withLock { () -> Bool in
                if self.closed { return true }
                self.subscriptionTasks.append(task)
                return false
            }
            if alreadyClosed { task.cancel() }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.forgetSubscription(task)
            }
        }
    }

    private func forgetSubscription(_ task: Task<Void, Never>) {
        lock.withLock {
            subscriptionTasks.removeAll { $0 == task }
        }
    }

    // MARK: - Internals

    /// Exchange the bootstrap credential for the session bearer + the
    /// instance id the reply advertises (cross-checked in the handshake).
    private func admitSession() async throws -> (bearerHex: String, instanceID: String) {
        try await withDeadline(Deadlines.handshake) { options in
            let reply = try await self.stub.admitSession(
                request: ClientRequest(
                    message: AppDaemonAdmitSessionRequest(),
                    metadata: Self.authorization(self.admission.bootstrapCredentialHex)),
                options: options)
            return (
                bearerHex: Self.hex(Array(reply.sessionCredential)),
                instanceID: reply.daemonInstanceID
            )
        }
    }

    private func getCapabilities(bearer: String) async throws -> AppDaemonGetCapabilitiesReply {
        return try await withDeadline(Deadlines.handshake) { options in
            try await self.stub.getCapabilities(
                request: ClientRequest(
                    message: AppDaemonGetCapabilitiesRequest(),
                    metadata: Self.authorization(bearer)),
                options: options)
        }
    }

    /// Synchronous bearer read (NSLock is unavailable from async bodies).
    private func requireBearerSync() throws -> String {
        let state = lock.withLock { (session?.bearerHex, closed) }
        guard let bearer = state.0 else {
            throw AppDaemonFailure(
                code: .unauthenticated, message: "bootstrap() has not completed")
        }
        guard !state.1 else {
            throw AppDaemonFailure(code: .unauthenticated, message: "Session is closed")
        }
        return bearer
    }

    private func withDeadline<T>(
        _ deadline: Duration, _ body: (CallOptions) async throws -> T
    ) async throws -> T {
        var options = CallOptions.defaults
        options.timeout = deadline
        options.maxResponseMessageBytes = Self.maxMessageBytes
        do {
            return try await body(options)
        } catch {
            throw Self.typed(error)
        }
    }

    /// The capabilities gate, before any workload call: contract version,
    /// daemon instance binding (the admission reply's instance id AND the
    /// capabilities reply's must agree with each other and the admission),
    /// and every capability this build requires.
    static func verifyCapabilities(
        _ reply: AppDaemonGetCapabilitiesReply,
        expectedInstance: String,
        advertisedInstance: String,
        admittedInstance: String
    ) throws {
        // Four-way agreement: the XPC admission, the AdmitSession reply,
        // and the capabilities reply must all name the same instance, and
        // it must be the one this session was built against.
        guard admittedInstance == expectedInstance else {
            throw AppDaemonFailure(
                code: .unauthenticated,
                message: "Handshake instance mismatch: admission bound to "
                    + "\(expectedInstance), AdmitSession answer for \(admittedInstance)")
        }
        guard advertisedInstance == expectedInstance else {
            throw AppDaemonFailure(
                code: .unauthenticated,
                message: "Handshake instance mismatch: admission bound to "
                    + "\(expectedInstance), capabilities answer for \(advertisedInstance)")
        }
        guard reply.contractVersion == requiredContractVersion else {
            throw AppDaemonFailure(
                code: .capabilityMismatch,
                message: "Daemon serves contract version \(reply.contractVersion); "
                    + "client requires \(requiredContractVersion)")
        }
        guard reply.daemonInstanceID == expectedInstance else {
            // Prior-instance credential: the endpoint answers, but it is not
            // the daemon this session authenticated against.
            throw AppDaemonFailure(
                code: .unauthenticated,
                message: "Credential is bound to daemon instance \(expectedInstance), "
                    + "but the endpoint answers for \(reply.daemonInstanceID)")
        }
        let served = Set(reply.capabilities)
        for required in requiredCapabilities where !served.contains(required) {
            throw AppDaemonFailure(
                code: .capabilityMismatch,
                message: "Daemon does not serve capability \(required)")
        }
    }

    static func authorization(_ bearerHex: String) -> GRPCCore.Metadata {
        var metadata = GRPCCore.Metadata()
        metadata.addString("Bearer \(bearerHex)", forKey: "authorization")
        return metadata
    }

    /// Convert a transport/framework error into the typed failure vocabulary.
    static func typed(_ error: any Error) -> any Error {
        if let rpcError = error as? RPCError {
            return AppDaemonFailure.error(from: rpcError)
        }
        if error is AppDaemonFailure || error is CancellationError {
            return error
        }
        return AppDaemonFailure(
            code: .unavailable, message: "Transport failure: \(error)", retryable: true)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
