#if os(macOS)
import Foundation

// The gRPC ENDPOINT ADMISSION wire (plans/app-daemon-wire-contract.md): XPC
// keeps launch, admission, and lifetime; the workload travels over gRPC. The
// app calls the daemon's `grpcAdmission` selector once per connection; the
// reply carries the endpoint path plus a short-lived bootstrap credential
// (30 s) that one gRPC call (AdmitSession) exchanges for the session bearer.
//
// The credential is opaque random 256 bits, issued by the daemon, bound to
// THIS XPC connection and daemon instance, and never logged by either side.
// Same-user socket permissions are NOT authentication.

public enum DaemonGRPCAdmissionWire {
    /// The request envelope's version. Versioned like every XPC envelope in
    /// this contract; the daemon rejects unknown versions as invalidRequest.
    public static let currentVersion = 1
}

public struct DaemonGRPCAdmissionRequest: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = DaemonGRPCAdmissionWire.currentVersion) {
        self.version = version
    }
}

/// The admission reply. `endpointAvailable` is false when the daemon's gRPC
/// listener is not serving (startup failure or unsupported layout) — the
/// client stays on XPC; the remaining fields are then meaningless.
public struct DaemonGRPCAdmissionReply: Codable, Equatable, Sendable {
    public let version: Int
    public let endpointAvailable: Bool

    /// The Unix domain socket path (mode-0700 private directory under the
    /// App Group container).
    public let socketPath: String?
    /// The short-lived bootstrap credential (hex, 64 chars / 256 bits).
    public let bootstrapCredentialHex: String?
    /// The daemon instance this credential is bound to.
    public let daemonInstanceID: String?
    /// The bootstrap window, as seconds from now. The exchange is idempotent
    /// within the window; after it expires the client asks XPC for a fresh
    /// bootstrap for the same live session.
    public let bootstrapValidForSeconds: Double?

    public init(
        version: Int = DaemonGRPCAdmissionWire.currentVersion,
        endpointAvailable: Bool,
        socketPath: String? = nil,
        bootstrapCredentialHex: String? = nil,
        daemonInstanceID: String? = nil,
        bootstrapValidForSeconds: Double? = nil
    ) {
        self.version = version
        self.endpointAvailable = endpointAvailable
        self.socketPath = socketPath
        self.bootstrapCredentialHex = bootstrapCredentialHex
        self.daemonInstanceID = daemonInstanceID
        self.bootstrapValidForSeconds = bootstrapValidForSeconds
    }

    /// The versioned failure reply (listener unavailable / unknown request
    /// version).
    public static func unavailable(
        version: Int = DaemonGRPCAdmissionWire.currentVersion
    ) -> DaemonGRPCAdmissionReply {
        DaemonGRPCAdmissionReply(endpointAvailable: false)
    }
}
#endif
