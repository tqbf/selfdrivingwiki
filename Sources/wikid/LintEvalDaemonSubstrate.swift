import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

/// The live-eval daemon substrate: the same components the daemon boots
/// (registry + domain dispatcher + socket server + registration broker),
/// serving ONLY a dedicated eval container's socket, plus the scoped-run
/// lease manager every lint launch requires (there is no unscoped lint
/// fallback).
///
/// Public for the WikiLintEval live gate driver — the only non-daemon
/// process allowed to boot this substrate, and only against an eval
/// container the operator's wikis never share.
/// Sendable invariant: both stored members are `let` and never mutated after
/// init (the server is stopped exactly once through `stop()` from the host's
/// teardown path), so any instance is safely shareable.
// swiftlint:disable:next unchecked_sendable
public final class LintEvalDaemonSubstrate: @unchecked Sendable {

    /// The scoped-run lease manager the driver installs on every trial's
    /// launcher (typed as the public engine protocol — the concrete actor
    /// stays internal to the daemon).
    public let leaseManager: any AgentScopedRunLeaseManaging

    private let server: DaemonSearchSocketServer

    /// The socket path the substrate serves (the eval container's
    /// `wikid-search.sock`). Diagnostics only — the host's stderr milestone
    /// names it so a wedge points at the endpoint the client must reach.
    public var socketPath: String { server.socketPath }

    /// Boot the substrate over `containerDirectory`'s socket with the
    /// PRODUCTION daemon composition (the same profile owner the wikid
    /// binary boots). Throws when the socket cannot be created or served —
    /// the driver surfaces that as a named `daemonUnavailable` prerequisite.
    public init(containerDirectory: URL) throws {
        let profileOwner = try DaemonProcessProfileOwner.production(
            containerDirectory: containerDirectory)
        let daemon = WikiDaemon(
            containerDirectory: containerDirectory,
            profileOwner: profileOwner,
            storeBootstrap: StoreBootstrap())
        // ONE registry shared by the dispatcher and the broker, so a scoped
        // run registered by the broker authorizes on the same dispatcher the
        // ordinary socket serves (the production wikid boot shape, and the
        // shape the scoped-run tests exercise).
        let runRegistry = DaemonRunRegistry()
        // The dispatcher's own receipt/verification state: the dispatcher
        // mints receipts and publishes written-version verification records
        // for the driver's post-run accounting and capture.
        let lintRunState = DaemonLintRunState()
        let dispatcher = DaemonDomainSocketDispatcher(
            daemon: daemon, runRegistry: runRegistry, lintRunState: lintRunState)
        let server = try DaemonSearchSocketServer(containerDirectory: containerDirectory) { request in
            await dispatcher.handle(request)
        }
        try server.start()
        let broker = DaemonRunRegistrationBroker(
            registry: runRegistry, dispatcher: dispatcher,
            containerDirectory: containerDirectory)
        self.server = server
        self.leaseManager = try DaemonScopedRunLeaseManager(
            broker: broker, containerDirectory: containerDirectory)
    }

    /// Stop serving and unlink the socket.
    public func stop() {
        server.stop()
    }
}
