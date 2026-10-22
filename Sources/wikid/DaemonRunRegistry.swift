#if os(macOS)
import CryptoKit
import Foundation
import Security
import WikiDaemonContract
import WikiFSCore

// The scoped-run authorization core (plans/agent-sandbox-scoping.md §5).
//
// Ownership and trust boundaries, in one place:
//
// - The TRUSTED RUN HOST (the launcher side; Phase 2 wires the broker)
//   generates the capability through the system random source and registers
//   the run BEFORE the child starts. The registry returns the printable
//   capability exactly once, at registration; from then on it stores only a
//   SHA-256 DIGEST — the printable secret is unrecoverable from anything the
//   daemon keeps.
// - Registration, activation, renewal, and revocation are owner-side APIs on
//   this actor. They are NOT reachable through the CLI socket: the domain
//   envelope has no family that reaches them, and the dispatcher's scoped
//   path only ever CALLS `authorize(capability:)`. A same-user child can
//   therefore never mint, renew, or widen a run.
// - Nothing is persisted. A daemon restart forgets every run, and every
//   outstanding capability stops authorizing (documented §5).
// - The lease is BOUNDED: it expires unless the trusted owner renews it, so
//   a crashed owner cannot leave authority behind. The child is never asked
//   to renew its own authority.

/// Typed run identity. Never a bare `String` internally — a run id cannot be
/// confused with a wiki id, a capability, or a queue item id.
public struct DaemonRunID: Hashable, Codable, Sendable, RawRepresentable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A fresh opaque identity (UUID is sufficient: run ids are compared,
    /// never ordered, and never used as filenames — endpoints name the run's
    /// opaque socket, not its id).
    static func generate() -> DaemonRunID {
        DaemonRunID(rawValue: UUID().uuidString)
    }

    public var description: String { rawValue }
}

/// The opaque per-run endpoint name (plans/agent-sandbox-scoping.md §4):
/// the socket FILE name inside the container's runs directory
/// (`r/<name>.sock`). Deliberately NOT the run id — endpoints name a
/// separate random token, so a leaked run id confers no knowledge of (or
/// ability to guess) a live endpoint path, and a leaked endpoint path
/// confers no run identity.
public struct DaemonRunEndpointName: Hashable, Codable, Sendable,
    RawRepresentable, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Random byte count behind one name: 12 bytes = 96 random bits (24
    /// lowercase-hex characters). Endpoint paths are length-budgeted
    /// (`SearchSocketWire.maxPathBytes`), so the leaf stays short while the
    /// collision space stays astronomically beyond enumeration.
    static let randomByteCount = 12

    public enum GenerationError: Error, Equatable {
        case randomSourceUnavailable(OSStatus)
    }

    /// A fresh opaque name from the system random source (`SecRandomCopyBytes`
    /// — the same source the capability uses).
    public static func generate() throws -> DaemonRunEndpointName {
        var bytes = [UInt8](repeating: 0, count: randomByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomByteCount, &bytes)
        guard status == errSecSuccess else {
            throw GenerationError.randomSourceUnavailable(status)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return DaemonRunEndpointName(rawValue: hex)
    }

    public var description: String { rawValue }
}

/// 256 random capability bits from the system random source
/// (`SecRandomCopyBytes`). The printable form (base64) is the ONLY form that
/// crosses a boundary — wire envelope (``DaemonDomainAuthorization``) or the
/// child environment (Phase 3's credential delivery) — and it is deliberately
/// redacted in every description hook so an accidental log interpolation
/// cannot leak it.
public struct DaemonRunCapability: Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// 256 bits.
    public static let byteCount = 32

    /// The raw random bytes. Never logged; never persisted by the daemon.
    public let secret: Data

    public enum GenerationError: Error, Equatable {
        /// `SecRandomCopyBytes` failed with this OSStatus.
        case randomSourceUnavailable(OSStatus)
    }

    /// Generate from the system random source.
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, Self.byteCount, &bytes)
        guard status == errSecSuccess else {
            throw GenerationError.randomSourceUnavailable(status)
        }
        self.secret = Data(bytes)
    }

    /// Decode the printable form carried on the wire or in the environment.
    /// `nil` unless the string is base64 for EXACTLY `byteCount` bytes — a
    /// truncated, padded, or oversized value is malformed, not short.
    public init?(printable: String) {
        guard let data = Data(base64Encoded: printable),
            data.count == Self.byteCount
        else { return nil }
        self.secret = data
    }

    /// The printable form that crosses boundaries.
    public var printable: String {
        secret.base64EncodedString()
    }

    public var description: String { "DaemonRunCapability(redacted)" }
    public var debugDescription: String { "DaemonRunCapability(redacted)" }
}

/// SHA-256 over the capability's printable form — the ONLY capability-derived
/// value the daemon stores. Equality of digests is exactly equality of
/// printable capabilities; the secret is not recoverable from the digest.
public struct DaemonRunCapabilityDigest: Hashable, Codable, Sendable {
    public let value: Data

    public init(capability: DaemonRunCapability) {
        self.init(printable: capability.printable)
    }

    public init(printable: String) {
        self.value = Data(SHA256.hash(data: Data(printable.utf8)))
    }
}

/// The operation classes a scoped run's lease may carry
/// (plans/agent-sandbox-scoping.md §6). The dispatcher's operation-policy
/// table classifies every family/operation pair into one of these (or a
/// denial); a run may exercise an operation only when its class is in the
/// lease.
public enum DaemonRunOperationClass: String, Codable, Sendable, CaseIterable {
    /// Page, source, chat, bookmark, strategy, workspace reads, wiki-bound
    /// search, and job reads — for the assigned wiki only.
    case wikiRead
    /// Approved edits within the assigned wiki; CAS requirements preserved.
    case wikiEdit
    /// Approved source additions and extraction enqueue for the assigned wiki.
    case wikiAcquire
}

/// The lease lifecycle (plans/agent-sandbox-scoping.md §5): a run is
/// `prepared` at registration (before the child starts), `active` once the
/// trusted owner starts the child, and `revoked` on any teardown path.
/// Revocation is idempotent. Only `active` authorizes.
public enum DaemonRunLeaseState: String, Codable, Sendable {
    case prepared
    case active
    case revoked
}

/// The run's scope: EXACTLY ONE wiki, by construction — the struct carries no
/// collection, so a multi-wiki scope is unrepresentable.
public struct DaemonRunScope: Hashable, Codable, Sendable {
    public let wikiID: WikiID

    public init(wikiID: WikiID) {
        self.wikiID = wikiID
    }
}

/// One registered run's lease. The digest is stored; the printable secret is
/// not a field, so it cannot leak out of the registry.
public struct DaemonRunLease: Sendable {
    public let id: DaemonRunID
    public let scope: DaemonRunScope
    public let operationClasses: Set<DaemonRunOperationClass>
    public let digest: DaemonRunCapabilityDigest
    /// The run's endpoint identity (§5: stored per run). `nil` for a lease
    /// registered without an endpoint — direct registry use that never binds
    /// a listener (the Phase 1 tests). The BROKER always names the endpoint.
    public let endpointName: DaemonRunEndpointName?
    /// Owner-renewed expiry bound (crash protection).
    public fileprivate(set) var state: DaemonRunLeaseState
    public fileprivate(set) var expiresAt: Date

    fileprivate init(
        id: DaemonRunID,
        scope: DaemonRunScope,
        operationClasses: Set<DaemonRunOperationClass>,
        digest: DaemonRunCapabilityDigest,
        endpointName: DaemonRunEndpointName?,
        state: DaemonRunLeaseState,
        expiresAt: Date
    ) {
        self.id = id
        self.scope = scope
        self.operationClasses = operationClasses
        self.digest = digest
        self.endpointName = endpointName
        self.state = state
        self.expiresAt = expiresAt
    }
}

/// The authorization decision: what the dispatcher may assume about the
/// request after the registry accepted its capability.
public struct DaemonRunGrant: Equatable, Sendable {
    public let runID: DaemonRunID
    public let scope: DaemonRunScope
    public let operationClasses: Set<DaemonRunOperationClass>
}

/// The registration outcome. The printable capability exists HERE and only
/// here; the caller (trusted run host) delivers it to the child out of band.
public struct DaemonRunRegistration: Sendable {
    public let runID: DaemonRunID
    public let capability: DaemonRunCapability
}

/// Invalid lease transitions and unknown runs. Internal detail — the
/// dispatcher surfaces only the four typed authorization errors.
public enum DaemonRunLeaseError: Error, Equatable {
    case unknownRun(DaemonRunID)
    case invalidTransition(runID: DaemonRunID, from: DaemonRunLeaseState, to: DaemonRunLeaseState)
    case emptyOperationClasses
}

/// The run registry: one actor, live only for this daemon process.
public actor DaemonRunRegistry {

    /// The default bounded-lease lifetime. The trusted owner renews before
    /// expiry for long-running sessions; an owner that dies (crash, force
    /// quit) leaves authority that expires on this bound rather than living
    /// forever.
    public static let defaultLeaseLifetime: Duration = .seconds(3600)

    /// Digest → run id: the authorization lookup.
    private var runsByDigest: [DaemonRunCapabilityDigest: DaemonRunID] = [:]
    private var leases: [DaemonRunID: DaemonRunLease] = [:]

    public init() {}

    // MARK: - Owner-side lifecycle (NOT reachable through the CLI socket)

    /// Register a run for ONE wiki: generate the capability, store the
    /// digest, start the lease `prepared` with a bounded expiry. Returns the
    /// registration carrying the printable capability — the only copy.
    /// `endpointName` stores the run's endpoint identity (§5) — the BROKER
    /// mints it and binds the matching listener; direct registry use may
    /// omit it (a lease with no endpoint).
    public func prepareRun(
        scope: DaemonRunScope,
        operationClasses: Set<DaemonRunOperationClass>,
        endpointName: DaemonRunEndpointName? = nil,
        lifetime: Duration = DaemonRunRegistry.defaultLeaseLifetime
    ) throws -> DaemonRunRegistration {
        guard !operationClasses.isEmpty else {
            throw DaemonRunLeaseError.emptyOperationClasses
        }
        let runID = DaemonRunID.generate()
        let capability = try DaemonRunCapability()
        let digest = DaemonRunCapabilityDigest(capability: capability)
        let lease = DaemonRunLease(
            id: runID,
            scope: scope,
            operationClasses: operationClasses,
            digest: digest,
            endpointName: endpointName,
            state: .prepared,
            expiresAt: Self.advance(.now, by: lifetime))
        leases[runID] = lease
        runsByDigest[digest] = runID
        return DaemonRunRegistration(runID: runID, capability: capability)
    }

    /// `prepared → active`: the trusted owner starts the child. Invalid from
    /// any other state.
    public func activate(runID: DaemonRunID) throws {
        try transition(runID: runID, to: .active)
    }

    /// Owner-side renewal: push the expiry out on the bounded lease. Allowed
    /// while the lease is live (`prepared` or `active`); denied once revoked
    /// — revocation is terminal.
    public func renew(
        runID: DaemonRunID,
        lifetime: Duration = DaemonRunRegistry.defaultLeaseLifetime
    ) throws {
        guard var lease = leases[runID] else {
            throw DaemonRunLeaseError.unknownRun(runID)
        }
        guard lease.state != .revoked else {
            throw DaemonRunLeaseError.invalidTransition(
                runID: runID, from: lease.state, to: lease.state)
        }
        lease.expiresAt = Self.advance(.now, by: lifetime)
        leases[runID] = lease
    }

    /// Revoke the run: terminal and IDEMPOTENT — revoking an unknown,
    /// already-revoked, or live run all settle the lease at `revoked`, so
    /// every teardown path can revoke unconditionally.
    public func revoke(runID: DaemonRunID) {
        guard var lease = leases[runID] else { return }
        lease.state = .revoked
        leases[runID] = lease
    }

    // MARK: - Authorization (the dispatcher's only entry)

    /// Authorize a presented capability. Throws the TYPED authorization
    /// errors (domain replies — never transport faults):
    ///
    /// - `authorizationInvalid`: malformed capability, no run registered
    ///   under its digest, or a `prepared` lease (registered, not yet
    ///   activated — the child cannot jump the gun).
    /// - `authorizationExpired`: the lease is over — past its expiry, or
    ///   revoked (both are "this capability no longer authorizes"; the reply
    ///   is identical, so lease state does not leak).
    ///
    /// The printable capability is digested and discarded; nothing about it
    /// is stored or echoed.
    public func authorize(
        capability: DaemonRunCapability,
        at now: Date = .now
    ) throws -> DaemonRunGrant {
        let digest = DaemonRunCapabilityDigest(capability: capability)
        guard let runID = runsByDigest[digest], let lease = leases[runID] else {
            throw DaemonDomainError(
                code: .authorizationInvalid,
                message: DaemonDomainError.genericAuthorizationMessage)
        }
        switch lease.state {
        case .prepared:
            throw DaemonDomainError(
                code: .authorizationInvalid,
                message: DaemonDomainError.genericAuthorizationMessage)
        case .revoked:
            throw DaemonDomainError(
                code: .authorizationExpired,
                message: DaemonDomainError.genericAuthorizationMessage)
        case .active:
            guard lease.expiresAt > now else {
                throw DaemonDomainError(
                    code: .authorizationExpired,
                    message: DaemonDomainError.genericAuthorizationMessage)
            }
        }
        return DaemonRunGrant(
            runID: runID,
            scope: lease.scope,
            operationClasses: lease.operationClasses)
    }

    /// The current lease, for diagnostics and tests. No capability material.
    public func lease(for runID: DaemonRunID) -> DaemonRunLease? {
        leases[runID]
    }

    /// How many runs are registered (diagnostics/tests).
    public func runCount() -> Int {
        leases.count
    }

    // MARK: - Internals

    /// `Date + Duration` has no overload; convert through the components.
    private static func advance(_ date: Date, by lifetime: Duration) -> Date {
        let (seconds, attoseconds) = lifetime.components
        return date.addingTimeInterval(
            Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000)
    }

    private func transition(runID: DaemonRunID, to newState: DaemonRunLeaseState) throws {
        guard var lease = leases[runID] else {
            throw DaemonRunLeaseError.unknownRun(runID)
        }
        let valid: Bool
        switch (lease.state, newState) {
        case (.prepared, .active):
            valid = true
        default:
            valid = false
        }
        guard valid else {
            throw DaemonRunLeaseError.invalidTransition(
                runID: runID, from: lease.state, to: newState)
        }
        lease.state = newState
        leases[runID] = lease
    }
}

extension DaemonDomainError {
    /// The fixed denial text for capability failures: names no wiki, no run,
    /// and echoes no credential. Every invalid/expired path uses it verbatim.
    public static let genericAuthorizationMessage =
        "the request is not authorized for this daemon connection"
}
#endif
