#if os(macOS)
import Foundation
import GRPCCore
import GRPCProtobuf
import WikiDaemonContract
import WikiDaemonGRPCContract

/// The daemon-side gRPC service implementation for the first slice
/// (credential admission, capabilities, registry read, registry events).
///
/// Shape per the contract: the provider is THIN. Workload answers come from
/// the injected ``Handlers`` (the same shared application operations the XPC
/// exporter routes to — one implementation, two transports); this class owns
/// only the transport-specific concerns: credential checks before dispatch,
/// family validation, bounded event forwarding, and typed failures.
///
/// Thrown errors: ``AppDaemonFailure`` values are converted to
/// `GoogleRPCStatus` (rich status with packed versioned details) right here
/// (``wire``); anything else surfaces as an INTERNAL status, never as a
/// credential or contract lie.
public final class AppDaemonServiceProvider: AppDaemonAppDaemon.ServiceProtocol, Sendable {

    /// The subscription's bounded buffer, in received-minus-forwarded events.
    /// A client that stops reading backs the loop up past this bound and the
    /// stream fails typed (RESYNC_REQUIRED) instead of growing without limit.
    public static let outstandingEventBound = 256

    /// Capability names this daemon serves. Stable dotted strings; clients
    /// check membership, not order.
    public static let capabilities = ["admission.v1", "registry.v1", "events.v1"]

    /// The contract version this daemon serves (the proto package version).
    public static let contractVersion: UInt32 = 1

    /// Shared application operations behind the transport boundary. Kept
    /// protocol-shaped so fixtures can drive every reply (the shipping wiring
    /// routes to the same operations the XPC exporter calls).
    public struct Handlers: Sendable {
        /// The wiki registry, MRU-ordered — the authoritative read.
        public var listWikis: @Sendable () async throws -> AppDaemonListWikisReply

        public init(
            listWikis: @escaping @Sendable () async throws -> AppDaemonListWikisReply
        ) {
            self.listWikis = listWikis
        }
    }

    private let store: DaemonSessionStore
    private let hub: DaemonRegistryEventHub
    private let handlers: Handlers
    /// The capabilities reply's contract version. Production uses
    /// ``Self/contractVersion``; the interop fixtures override it to prove
    /// the client's incompatible-capabilities gate.
    private let servedContractVersion: UInt32
    /// The instance id served in replies. Production uses the store's fresh
    /// per-process id; fixtures fix it to the corpus value.
    private let servedInstanceID: String

    public init(
        store: DaemonSessionStore,
        hub: DaemonRegistryEventHub,
        handlers: Handlers,
        contractVersion: UInt32? = nil,
        daemonInstanceID: String? = nil
    ) {
        self.store = store
        self.hub = hub
        self.handlers = handlers
        self.servedContractVersion = contractVersion ?? Self.contractVersion
        self.servedInstanceID = daemonInstanceID ?? store.daemonInstanceID
    }

    // MARK: - Admission

    public func admitSession(
        request: GRPCCore.ServerRequest<AppDaemonAdmitSessionRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<AppDaemonAdmitSessionReply> {
        try await wire {
            let bootstrap = try Self.bearerCredential(from: request.metadata)
            guard let sessionHex = store.exchange(bootstrapHex: bootstrap) else {
                throw AppDaemonFailure(
                    code: .unauthenticated,
                    message: "Missing, expired, or revoked admission credential")
            }
            let reply = AppDaemonAdmitSessionReply.with {
                $0.sessionCredential = Data(Self.credentialBytes(sessionHex))
                $0.daemonInstanceID = servedInstanceID
                $0.admittedAt = .init(date: Date())
            }
            return GRPCCore.ServerResponse(message: reply)
        }
    }

    // MARK: - Capabilities

    public func getCapabilities(
        request: GRPCCore.ServerRequest<AppDaemonGetCapabilitiesRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<AppDaemonGetCapabilitiesReply> {
        try await wire {
            // Session check BEFORE the handshake answer: a missing/expired/
            // revoked credential never learns the daemon's shape.
            _ = try authenticate(request.metadata)
            let reply = AppDaemonGetCapabilitiesReply.with {
                $0.contractVersion = servedContractVersion
                $0.daemonInstanceID = servedInstanceID
                $0.capabilities = Self.capabilities
                $0.servedAt = .init(date: Date())
            }
            return GRPCCore.ServerResponse(message: reply)
        }
    }

    // MARK: - Registry

    public func listWikis(
        request: GRPCCore.ServerRequest<AppDaemonListWikisRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<AppDaemonListWikisReply> {
        try await wire {
            _ = try authenticate(request.metadata)
            let reply = try await handlers.listWikis()
            return GRPCCore.ServerResponse(message: reply)
        }
    }

    // MARK: - Events

    public func subscribeEvents(
        request: GRPCCore.ServerRequest<AppDaemonSubscribeEventsRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<AppDaemonDaemonEvent> {
        // Authenticate + validate families BEFORE the stream exists: a
        // missing credential or unserved family is a typed unary status, not
        // a stream that dies after one frame.
        let session = try await wire {
            let authenticated = try authenticate(request.metadata)
            // First slice: REGISTRY only. Reject anything else so a client
            // never believes a family is flowing when it is not.
            for family in request.message.families {
                guard family == .registry else {
                    throw AppDaemonFailure(
                        code: .invalidRequest,
                        message: "Event family not served by this contract version: \(family.rawValue)")
                }
            }
            return authenticated
        }

        return GRPCCore.StreamingServerResponse(metadata: [:]) { writer in
            try await self.wire {
                let handle = SubscriptionHandle(hub: self.hub, sessionHex: session.credentialHex)
                self.store.registerStream(sessionHex: session.credentialHex, handle)
                defer {
                    self.store.unregisterStream(sessionHex: session.credentialHex, id: handle.id)
                }

                let events = self.hub.subscribe()
                var outstanding = 0
                for await event in events {
                    // nil = termination sentinel: hub shutdown or session
                    // revocation. Plain end: the client resyncs from
                    // authoritative state.
                    guard let event else { return GRPCCore.Metadata() }
                    outstanding += 1
                    if outstanding > Self.outstandingEventBound {
                        throw AppDaemonFailure(
                            code: .resyncRequired,
                            message: "Subscription buffer overflow; resync from authoritative state")
                    }
                    try await writer.write(event)
                    outstanding -= 1
                }
                return GRPCCore.Metadata()
            }
        }
    }

    // MARK: - Auth plumbing

    /// Boundary error conversion: AppDaemonFailure becomes the rich status
    /// (typed details in `grpc-status-details-bin`); anything else rethrows
    /// unchanged so the framework's honest INTERNAL mapping applies.
    private func wire<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as AppDaemonFailure {
            throw failure.googleRPCStatus(instanceID: servedInstanceID)
        }
    }

    /// Validate the bearer credential BEFORE any workload dispatch. Throws
    /// typed UNAUTHENTICATED for missing/unknown/revoked/prior-instance
    /// credentials.
    private func authenticate(
        _ metadata: GRPCCore.Metadata
    ) throws -> DaemonSessionStore.SessionContext {
        let bearer = try Self.bearerCredential(from: metadata)
        guard let session = store.validate(bearerHex: bearer) else {
            throw AppDaemonFailure(
                code: .unauthenticated,
                message: "Missing, expired, or revoked session credential")
        }
        return session
    }

    private static func bearerCredential(from metadata: GRPCCore.Metadata) throws -> String {
        for value in metadata[stringValues: "authorization"] {
            let string = value.trimmingCharacters(in: .whitespaces)
            if string.lowercased().hasPrefix("bearer ") {
                return String(string.dropFirst("bearer ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        throw AppDaemonFailure(code: .unauthenticated, message: "authorization metadata missing")
    }

    /// Hex-string credential → the 32 bytes the reply message carries.
    static func credentialBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex,
              let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index ..< next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }

    /// A registered live subscription. Session revocation calls
    /// ``finish()`` (idempotent): the stream ends client-visible with a
    /// plain end and the client resyncs. The handle owns its id BEFORE it is
    /// registered, so revocation can never race a registration into a
    /// missed termination.
    // The `terminated` flag is covered by `lock`; hub + session hex are
    // immutable after init.
    // swiftlint:disable:next unchecked_sendable
    private final class SubscriptionHandle: DaemonSessionStore.SessionStreamHandle, @unchecked Sendable {
        let id = UUID()
        private let hub: DaemonRegistryEventHub
        private let sessionHex: String
        private let lock = NSLock()
        private var terminated = false

        init(hub: DaemonRegistryEventHub, sessionHex: String) {
            self.hub = hub
            self.sessionHex = sessionHex
        }

        func finish() {
            lock.lock()
            guard !terminated else {
                lock.unlock()
                return
            }
            terminated = true
            lock.unlock()
            hub.close(subscriptionID: id)
        }
    }
}
#endif
