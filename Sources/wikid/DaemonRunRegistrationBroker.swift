#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// The trusted registration broker (plans/agent-sandbox-scoping.md §5).
//
// The TRUSTED RUN HOST — the daemon's own launcher process — mints the
// 256-bit capability (through ``DaemonRunRegistry``), registers the digest +
// scope + policy + bounded lease, binds the run's endpoint listener, and
// receives the endpoint path + printable capability for delivery to the
// child. Registration, renewal, and revocation are IN-PROCESS APIs: nothing
// here is reachable through the CLI socket (the domain envelope has no family
// that reaches this actor), so a same-user child can never mint, renew, or
// widen a run.
//
// WHY IN-PROCESS ONLY — the §5 separate-app-host audit (recorded 2026-10-22,
// Phase 2): `WikiDaemonListenerDelegate.listener(_:shouldAcceptNewConnection:)`
// in `Sources/wikid/main.swift` performs NO server-side peer validation — no
// audit-token check, no `SecCode`/code-signing validation, no effective-uid
// check; it unconditionally accepts every connection and exports
// `WikiDaemonProtocol`. The existing XPC channel is therefore NOT an
// authenticated control channel, and per §5 ("Do not assume the existing XPC
// channel authenticates the app sufficiently. Audit that channel before
// exposing registration.") registration is gated behind the in-process path
// only. Exposing it to a separate app host REQUIRES adding peer validation
// (audit token + code-identity requirement) to the XPC listener first; a
// managed launch must stop, not fall back, if that authentication fails.
//
// Endpoint layout (§4): `<container>/r/<opaque>.sock`. The opaque leaf is a
// separate random token (NOT the run id), the complete UTF-8 path is
// length-validated BEFORE registration (sockaddr_un's 103-byte bound), and
// the listener captures the run identity at construction.

/// What the trusted host receives from one successful registration: the
/// printable capability (the only copy — the daemon stores just its digest),
/// the endpoint path for the Seatbelt allow-rule and the child environment,
/// and the run identity for later renew/revoke calls.
struct DaemonScopedRunHandle: Sendable {
    let runID: DaemonRunID
    let scope: DaemonRunScope
    /// The run endpoint's absolute path (`<container>/r/<opaque>.sock`).
    let endpointPath: String
    /// The printable capability. Deliver to the child out of band (§7);
    /// never log it — ``DaemonRunCapability``'s descriptions are redacted.
    let capability: DaemonRunCapability
}

/// One actor per daemon process; holds the run's listeners for the run
/// lifetime. Revocation is idempotent so every teardown path can call it
/// unconditionally.
actor DaemonRunRegistrationBroker {

    /// The runs directory INSIDE the App Group container (§4's `r/`).
    static let runsDirectoryName = "r"
    /// The endpoint file suffix. Short names + short suffix keep the whole
    /// path inside `sockaddr_un`'s budget on typical containers.
    static let endpointFileSuffix = ".sock"

    private let registry: DaemonRunRegistry
    private let dispatcher: DaemonDomainSocketDispatcher
    private let containerDirectory: URL
    /// Run-lifetime listeners, keyed by run. Locked by actor isolation;
    /// entries are removed exactly by ``revoke(runID:)``.
    private var listeners: [DaemonRunID: DaemonRunSocketListener] = [:]

    init(
        registry: DaemonRunRegistry,
        dispatcher: DaemonDomainSocketDispatcher,
        containerDirectory: URL
    ) {
        self.registry = registry
        self.dispatcher = dispatcher
        self.containerDirectory = containerDirectory
    }

    /// The full trusted-owner sequence for one managed run:
    ///
    /// 1. mint the opaque endpoint name (system random, never the run id);
    /// 2. compose + length-validate the complete endpoint path BEFORE any
    ///    registration (§4) — a container whose path cannot fit
    ///    `sockaddr_un` is a configuration error, surfaced as
    ///    ``SearchSocketError/pathTooLong(limit:actual:)``;
    /// 3. register the run (capability minted, digest stored, lease
    ///    `prepared` with the bounded owner-renewed expiry);
    /// 4. bind the endpoint listener (the captured run identity stamps
    ///    `.scopedRun` on every accepted connection); a failed bind REVOKES
    ///    the fresh lease before throwing — no active authority is ever left
    ///    behind without its endpoint;
    /// 5. activate the lease (`prepared → active`) — the child may now
    ///    authorize against it.
    func launchScopedRun(
        scope: DaemonRunScope,
        operationClasses: Set<DaemonRunOperationClass>,
        operationPolicy: ManagedRunPolicy = .ordinaryManaged,
        lifetime: Duration = DaemonRunRegistry.defaultLeaseLifetime
    ) async throws -> DaemonScopedRunHandle {
        let name = try DaemonRunEndpointName.generate()
        let endpointPath = Self.endpointPath(
            inContainerDirectory: containerDirectory, name: name)
        // §4: validate the complete UTF-8 path BEFORE registration.
        let pathBytes = endpointPath.utf8.count
        guard pathBytes <= SearchSocketWire.maxPathBytes else {
            throw SearchSocketError.pathTooLong(
                limit: SearchSocketWire.maxPathBytes, actual: pathBytes)
        }

        let registration = try await registry.prepareRun(
            scope: scope,
            operationClasses: operationClasses,
            operationPolicy: operationPolicy,
            endpointName: name,
            lifetime: lifetime)
        let listener: DaemonRunSocketListener
        do {
            listener = try DaemonRunSocketListener(
                runID: registration.runID,
                endpointPath: endpointPath,
                dispatcher: dispatcher)
            try listener.start()
        } catch {
            // No bound endpoint → no live authority. Revoke (idempotent)
            // before surfacing the bind failure.
            await registry.revoke(runID: registration.runID)
            throw error
        }
        do {
            try await registry.activate(runID: registration.runID)
        } catch {
            listener.stop()
            await registry.revoke(runID: registration.runID)
            throw error
        }
        listeners[registration.runID] = listener
        return DaemonScopedRunHandle(
            runID: registration.runID,
            scope: scope,
            endpointPath: endpointPath,
            capability: registration.capability)
    }

    /// Owner-side renewal passthrough (the bounded lease's crash protection).
    /// Denied once revoked — revocation is terminal.
    func renew(
        runID: DaemonRunID,
        lifetime: Duration = DaemonRunRegistry.defaultLeaseLifetime
    ) async throws {
        try await registry.renew(runID: runID, lifetime: lifetime)
    }

    /// Revoke the run: terminal registry revocation PLUS listener teardown
    /// (stop accepting, close live connections, UNLINK the endpoint — §5's
    /// "close and unlink the endpoint"). Idempotent twice over: the
    /// registry's revoke is idempotent, and revoking an unknown run (or an
    /// already-revoked one) settles quietly. Requests already admitted on a
    /// live connection finish unless their operation cancels; new
    /// connections fail with ENOENT once the file is unlinked.
    func revoke(runID: DaemonRunID) async {
        await registry.revoke(runID: runID)
        if let listener = listeners.removeValue(forKey: runID) {
            listener.stop()
        }
    }

    /// Whether the broker still holds a live listener for the run
    /// (diagnostics/tests).
    func hasListener(runID: DaemonRunID) -> Bool {
        listeners[runID] != nil
    }

    /// The endpoint path for one opaque name inside the container:
    /// `<container>/r/<name>.sock`.
    static func endpointPath(
        inContainerDirectory containerDirectory: URL,
        name: DaemonRunEndpointName
    ) -> String {
        containerDirectory
            .appendingPathComponent(runsDirectoryName, isDirectory: true)
            .appendingPathComponent(name.rawValue + endpointFileSuffix)
            .path
    }
}
#endif
