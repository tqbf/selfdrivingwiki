#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Run-lifetime listener (plans/agent-sandbox-scoping.md §4).
//
// One listener per scoped run, bound for the RUN's lifetime: created when the
// trusted broker binds the endpoint at activation, unlinked when revocation
// tears it down. The run identity is captured HERE, at construction, as an
// immutable constant — it is a property of the listener, never of the wire,
// so no envelope field (or missing/malformed one) can change which run a
// connection belongs to. Every accepted connection is answered through the
// shared domain dispatcher under the `.scopedRun(runID)` connection context;
// the dispatcher's scoped gate (authorization → operation policy → target
// scope) runs before any family handler.
//
// Everything byte-level — same-user getpeereid gate before the first byte,
// 4 MiB frame cap, per-phase deadlines, one request + one reply per
// connection, nonblocking I/O — is the ordinary `DaemonSearchSocketServer`
// machinery, reused via its `runEndpointPath:` initializer (no duplicated
// server). The differences are lifecycle-only: no guard flock, no stale-socket
// unlink; the broker's revoke is the only unlink.
//
// Sendable invariant: `runID`, `socketPath`, and `server` are immutable after
// init; the server is internally synchronized (its own state lock).
// swiftlint:disable:next unchecked_sendable
final class DaemonRunSocketListener: @unchecked Sendable {

    /// The run this endpoint serves — captured at construction, immutable.
    let runID: DaemonRunID
    /// The bound socket path (`<container>/r/<opaque>.sock`).
    let socketPath: String

    private let server: DaemonSearchSocketServer

    /// Compose the listener for one run. The handler closure stamps the
    /// captured run identity on every connection; the dispatcher parameter
    /// is the daemon's ONE shared dispatcher, so scoped requests run the
    /// same family handlers as the ordinary socket (after their gate).
    /// Binding happens in `start()` — construction only validates and
    /// captures.
    init(
        runID: DaemonRunID,
        endpointPath: String,
        dispatcher: DaemonDomainSocketDispatcher
    ) throws {
        self.runID = runID
        self.socketPath = endpointPath
        self.server = try DaemonSearchSocketServer(
            runEndpointPath: endpointPath,
            handler: { [dispatcher, runID] request in
                // The CAPTURED identity — nothing on the wire participates.
                await dispatcher.handle(request, context: .scopedRun(runID))
            })
    }

    /// Bind + accept. Fails closed on any pre-existing file at the path
    /// (``SearchSocketError/endpointInUse(path:)``) — a second bind of a
    /// live endpoint never succeeds.
    func start() throws {
        try server.start()
    }

    /// Terminal teardown: stop accepting, close live connections, UNLINK the
    /// endpoint. Idempotent (mirrors the server's stop semantics), so the
    /// broker's revoke can call it unconditionally on every teardown path.
    func stop() {
        server.stop()
    }
}
#endif
