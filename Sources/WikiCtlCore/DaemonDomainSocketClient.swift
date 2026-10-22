#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

/// One framed request/reply round trip over the CLI ⇄ daemon socket: connect
/// → write one length-prefixed frame → read one length-prefixed frame →
/// close. Shared by the search transport (`DaemonSearchSocketClient`) and the
/// domain-envelope client below so the I/O loop has exactly one copy.
///
/// Every phase runs under the `timeout` deadline; bounds are enforced in both
/// directions (an oversized request fails with
/// ``SearchSocketError/frameTooLarge(_:)`` BEFORE connecting; an oversized
/// announced reply length throws before buffering). A missing or refusing
/// socket surfaces as ``SearchSocketError/daemonNotRunning(path:)`` — the
/// explicit "the app is not running" signal.
enum DaemonSocketRoundTrip {

    static func perform(
        socketPath: String,
        requestBytes: Data,
        timeout: TimeInterval
    ) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        // Client-side bound, checked before any socket is opened.
        guard requestBytes.count <= Int(SearchSocketWire.maxFrameSize) else {
            throw SearchSocketError.frameTooLarge(UInt32(requestBytes.count))
        }
        let fd = try await SearchSocketIO.connectSocket(path: socketPath, deadline: deadline)
        defer { close(fd) }
        try await SearchSocketIO.sendAll(
            fd: fd, bytes: SearchSocketWire.framed(requestBytes), deadline: deadline)
        var parser = SearchSocketWire.FrameParser()
        while true {
            if let payload = try parser.nextPayload() {
                return payload
            }
            try SearchSocketIO.checkDeadline(deadline, operation: "recv")
            switch SearchSocketIO.recvOnce(fd: fd) {
            case .data(let chunk):
                parser.append(chunk)
            case .eof:
                // The daemon closed before a complete reply: transport failure.
                throw SearchSocketError.incompleteFrame
            case .again:
                try await SearchSocketIO.awaitReady(
                    fd: fd, writable: false, deadline: deadline, operation: "recv")
            case .failed(let error):
                throw error
            }
        }
    }
}

/// Client for the daemon's versioned domain envelope (`DaemonDomainWire`) —
/// the CLI's access to every socket-served family (hello, search, queue,
/// wiki). One connection per call, one request per connection; the reply's
/// `requestID` must echo the request's and a typed `DaemonDomainError` in the
/// reply is thrown as-is, so family code sees the daemon's rejections typed.
//
// Immutable Sendable values (socket path + timeout).
public struct DaemonDomainSocketClient: Sendable {

    public let socketPath: String
    public let timeout: TimeInterval

    /// Binds the client to one container directory (the same directory the
    /// daemon was handed at boot). Throws eagerly when the resolved socket
    /// path cannot fit `sockaddr_un`.
    public init(
        containerDirectory: URL,
        timeout: TimeInterval = DaemonWorkloadClient.defaultTimeout
    ) throws {
        self.socketPath = try SearchSocketWire.socketPath(inContainerDirectory: containerDirectory)
        self.timeout = timeout
    }

    /// One envelope round trip. Throws `DaemonDomainError` for daemon
    /// rejections and `SearchSocketError` for transport faults.
    public func send(
        family: DaemonDomainFamily,
        operation: String,
        payload: Data? = nil
    ) async throws -> DaemonDomainReply {
        let request = DaemonDomainRequest(
            requestID: UUID().uuidString,
            family: family,
            operation: operation,
            payload: payload)
        let replyBytes = try await DaemonSocketRoundTrip.perform(
            socketPath: socketPath,
            requestBytes: try DaemonDomainWire.encode(request),
            timeout: timeout)
        let reply = try DaemonDomainWire.decodeReply(replyBytes)
        guard reply.requestID == request.requestID else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "daemon reply requestID did not match the request")
        }
        if let error = reply.error {
            throw error
        }
        return reply
    }

    /// The `hello`/`capabilities` handshake: what protocol version the daemon
    /// serves, which families it answers, and its build identity. A newer CLI
    /// against an older daemon uses this to report "requires app ≥ build N"
    /// instead of a raw transport error.
    public func hello() async throws -> DaemonHelloPayload {
        let reply = try await send(
            family: .hello,
            operation: DaemonDomainOperation.Hello.capabilities)
        guard let payload = reply.payload else {
            throw DaemonDomainError(
                code: .invalidRequest,
                message: "hello reply carried no capabilities payload")
        }
        return try DaemonDomainWire.decodeHelloPayload(payload)
    }
}
#endif
