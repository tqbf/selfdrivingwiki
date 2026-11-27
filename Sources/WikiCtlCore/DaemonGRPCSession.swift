#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiDaemonGRPC
import WikiDaemonGRPCContract
import WikiFSCore

/// The app-side gRPC session over the XPC-admitted endpoint.
///
/// Composition (plans/app-daemon-wire-contract.md): one XPC connection →
/// one admission (endpoint + bootstrap) → one gRPC session client. The
/// bootstrap exchange and capabilities check happen at session start; a
/// failed handshake leaves the session closed and the caller on XPC. On XPC
/// interruption the app closes this session and reconnects from a fresh
/// baseline — the daemon revoked the old session when the connection died.
///
/// This is the registry family's typed adapter. Later families add their
/// own adapters against the same session client; none of them go through
/// `RemoteWikiStoreTransport.call`.
// `client` is written once at the end of start() and read-only after; the
// class is used from the app's session bootstrap path (single caller).
// swiftlint:disable:next unchecked_sendable
public final class DaemonGRPCSession: @unchecked Sendable {

    /// Why a session could not start. Typed: callers branch, never parse.
    public enum StartFailure: Error, Equatable, Sendable {
        /// The daemon answered `endpointAvailable == false` (listener not
        /// serving). XPC remains the route.
        case endpointUnavailable
        /// The XPC admission call failed (daemon unreachable / unexpected
        /// reply).
        case admissionFailed
        /// The gRPC bootstrap or capabilities gate failed. Carries the typed
        /// contract failure when it came from the wire.
        case bootstrapFailed(AppDaemonFailure?)
    }

    /// The XPC connection backing admission (and revocation signaling).
    private let connection: WikiDaemonConnection
    /// The gRPC session client (nil until admitted + bootstrapped).
    private var client: AppDaemonSessionClient?

    public init(connection: WikiDaemonConnection) {
        self.connection = connection
    }

    /// Admit + bootstrap. Throws ``StartFailure`` — typed, never a string
    /// match. On success the session is ready for workload calls.
    public func start() async throws {
        let admissionReply: DaemonGRPCAdmissionReply
        do {
            admissionReply = try await connection.grpcAdmission()
        } catch {
            throw StartFailure.admissionFailed
        }
        guard admissionReply.endpointAvailable,
              let socketPath = admissionReply.socketPath,
              let bootstrap = admissionReply.bootstrapCredentialHex,
              let instanceID = admissionReply.daemonInstanceID else {
            throw StartFailure.endpointUnavailable
        }
        let validFor = admissionReply.bootstrapValidForSeconds ?? 30
        let admission = AppDaemonAdmission(
            socketPath: socketPath,
            bootstrapCredentialHex: bootstrap,
            daemonInstanceID: instanceID,
            expiresAt: Date().addingTimeInterval(validFor))
        let sessionClient = try AppDaemonSessionClient(admission: admission)
        do {
            try await sessionClient.bootstrap()
        } catch {
            sessionClient.close()
            throw StartFailure.bootstrapFailed(error as? AppDaemonFailure)
        }
        client = sessionClient
    }

    /// The wiki registry, MRU-ordered — typed domain values.
    public func listWikis() async throws -> [WikiDescriptor] {
        guard let client else {
            throw StartFailure.bootstrapFailed(nil)
        }
        let reply = try await client.listWikis()
        return try reply.wikis.map(GRPCRegistryWireMapping.descriptor)
    }

    /// Live registry events. Ends or fails typed (resyncRequired on
    /// overflow/epoch); the caller re-lists (``listWikis``) and
    /// re-subscribes. Cancel by cancelling the consumer task.
    public func subscribeRegistryEvents()
        -> AsyncThrowingStream<AppDaemonRegistryEvent, Error>
    {
        guard let client else {
            return AsyncThrowingStream { $0.finish(throwing: StartFailure.bootstrapFailed(nil)) }
        }
        return client.subscribeRegistryEvents()
    }

    /// Close the session client-side (XPC interruption, app shutdown). The
    /// daemon revokes server-side when the XPC connection dies.
    public func close() {
        client?.close()
        client = nil
    }

    deinit {
        close()
    }
}

/// The client-side wire↔domain registry mapping. Mirrors the daemon-side
/// mapping in `GRPCRegistryMapping` (wikid) — same fields, both directions
/// covered by the interop fixtures.
enum GRPCRegistryWireMapping {
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
