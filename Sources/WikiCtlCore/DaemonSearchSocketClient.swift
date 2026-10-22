#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// CLI-side transport factory: a `DaemonSearchTransport` that carries one
/// request/reply round trip over a bounded local AF_UNIX socket to the
/// daemon's search endpoint (`WikiDaemon.searchData(request:)`). The search
/// payload rides inside the versioned domain envelope (`DaemonDomainWire`,
/// Phase 1 of plans/cli-domain-commands.md) on the same socket file every
/// CLI⇄daemon family shares.
///
/// Why a socket: `NSXPCConnection(serviceName:)` is app-only (provably
/// lookup3 outside a host app), so the standalone `wikictl` binary cannot
/// reach the daemon over XPC. The daemon publishes the same `Data -> Data`
/// search contract on a length-prefixed, hard-capped, deadline-bounded
/// socket instead (see `DaemonSearchSocketServer`).
///
/// Contract:
/// - The returned closure opens a FRESH connection per call (one request per
///   connection — no persistent fd to leak) and closes it before returning;
///   `defer` guarantees the close on every path.
/// - Every phase (connect/send/recv) runs under the `timeout` deadline; a
///   deadline overrun surfaces as ``SearchSocketError/timeout(operation:)``.
///   `DaemonSearchClient` additionally wraps calls in its own cancellation-
///   safe outer bound (``DaemonSearchClient/defaultTimeout``, 30 s); a
///   straggler round trip is absorbed by its reply box and the transport fd
///   closes at the transport deadline — no hang, no leak.
/// - Bounds are enforced in both directions: an oversized request fails with
///   ``SearchSocketError/frameTooLarge(_:)`` BEFORE connecting; an oversized
///   announced reply length throws the same error before buffering.
/// - A missing or refusing socket surfaces as
///   ``SearchSocketError/daemonNotRunning(path:)`` — the caller's cue for
///   "the app is not running".
public enum DaemonSearchSocketClient {

    /// Builds a transport closure bound to one container directory. Throws
    /// eagerly when the resolved socket path cannot fit `sockaddr_un`.
    ///
    /// - Parameters:
    ///   - containerDirectory: the App Group container (the same directory
    ///     the daemon was handed at boot).
    ///   - timeout: deadline for the whole socket round trip, in seconds.
    ///     Defaults to ``DaemonSearchClient/defaultTimeout`` so one number
    ///     documents the worst case. Keep it at or above any injected
    ///     `DaemonSearchClient` timeout so the outer cancellation-safe bound
    ///     remains the visible failure.
    public static func transport(
        containerDirectory: URL,
        timeout: TimeInterval = DaemonSearchClient.defaultTimeout,
        authorization: DaemonDomainAuthorization? = nil
    ) throws -> DaemonSearchTransport {
        let socketPath = try SearchSocketWire.socketPath(inContainerDirectory: containerDirectory)
        return { request, reply in
            // Unstructured on purpose: the transport seam is callback-shaped
            // (`DaemonSearchTransport`), no task handle escapes, and the work
            // is bounded by the deadline below. The continuation-based I/O in
            // `SearchSocketIO` never parks a cooperative-pool thread.
            Task.detached(priority: .userInitiated) {
                let result: Result<Data, Error>
                do {
                    // The raw-size check happens on the UNWRAPPED search
                    // request so an oversized search still reports its own
                    // exact byte count (the wire contract the CLI tests pin)
                    // before the envelope's slightly larger frame is checked.
                    guard request.count <= Int(SearchSocketWire.maxFrameSize) else {
                        throw SearchSocketError.frameTooLarge(UInt32(request.count))
                    }
                    // Phase 1 of plans/cli-domain-commands.md: the search
                    // payload rides inside the versioned domain envelope; the
                    // SearchRPCRequest/SearchRPCReply bytes are unchanged.
                    // §6: a scoped run's authorization rides the SAME
                    // envelope — no legacy search frame may bypass it.
                    let envelope = DaemonDomainRequest(
                        requestID: UUID().uuidString,
                        family: .search,
                        operation: DaemonDomainOperation.Search.search,
                        payload: request,
                        authorization: authorization)
                    let replyBytes = try await DaemonSocketRoundTrip.perform(
                        socketPath: socketPath,
                        requestBytes: try DaemonDomainWire.encode(envelope),
                        timeout: timeout)
                    let envelopeReply = try DaemonDomainWire.decodeReply(replyBytes)
                    if let error = envelopeReply.error {
                        throw error
                    }
                    result = .success(envelopeReply.payload ?? Data())
                } catch {
                    DebugLog.store("wikictl: search socket transport failed: \(error)")
                    result = .failure(error)
                }
                reply(result)
            }
        }
    }
}
#endif
