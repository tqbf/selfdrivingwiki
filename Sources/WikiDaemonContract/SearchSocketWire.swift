#if os(macOS)
import Foundation

// Shared wire contract for the wikictl ⇄ wikid search socket transport — the
// bounded local AF_UNIX alternative for the standalone CLI, which cannot use
// the app-only `NSXPCConnection(serviceName:)` (provably lookup3 outside a
// host app).
//
// Protocol: one connection carries exactly ONE request and ONE reply, each a
// length-prefixed frame (UInt32 big-endian byte count + payload). The payload
// is the existing JSON `SearchRPCRequest` / `SearchRPCReply` encoding, so
// this transport reuses `WikiDaemon.searchData(request:) async -> Data`
// verbatim. Search-only: no mutating endpoint exists on this transport.
//
// Security/threat model (documented contract):
// - The socket lives in the App Group container. The server tightens the
//   directory to 0o700 (only when looser) and chmods the socket to 0o600.
// - On accept the server verifies the peer's effective uid with getpeereid(2)
//   and drops any other user before reading a byte. Read-only search against
//   the same user's database makes the same-user boundary the correct trust
//   level — defense in depth on top of the directory and socket permissions.
// - Frames are hard-capped at ``maxFrameSize`` and every I/O phase runs under
//   a deadline, so a stuck or hostile peer cannot pin an fd forever.
//
// This file stays a Foundation(+Dispatch)-only leaf — no domain imports, no
// dependency cycles. It is shared verbatim by the CLI client
// (`Sources/WikiCtlCore/DaemonSearchSocketClient.swift`) and the daemon
// server (`Sources/wikid/DaemonSearchSocketServer.swift`).

public enum SearchSocketWire {

    // MARK: File layout inside the container directory

    /// The listening socket file, directly inside the App Group container —
    /// short enough for `sockaddr_un.sun_path` even with the container's
    /// long path.
    public static let socketFileName = "wikid-search.sock"

    /// Process-lifetime flock guard file. The server holds an exclusive
    /// non-blocking flock for as long as it owns the socket; a second live
    /// server therefore fails at init, BEFORE it could unlink a served
    /// socket. The flock dies with the process, so after a crash the
    /// leftover socket file is provably ownerless and safe to clean up.
    public static let guardFileName = "wikid-search.lock"

    // MARK: Bounds

    /// `sockaddr_un.sun_path` is 104 bytes on macOS INCLUDING the trailing
    /// NUL, so a path may carry at most 103 UTF-8 bytes.
    public static let maxPathBytes = 103

    /// Length-prefix width on the wire.
    public static let lengthPrefixBytes = 4

    /// Hard cap on one frame's payload. A search request/reply is a JSON
    /// document of at most a few hundred KiB (worst case: a huge hit list);
    /// 4 MiB leaves an order of magnitude of headroom while keeping a hostile
    /// length prefix from pinning memory.
    public static let maxFrameSize: UInt32 = 4 * 1024 * 1024

    /// Scratch read chunk used by the nonblocking recv loop.
    static let readChunkSize = 64 * 1024

    // MARK: Paths

    /// Resolves and validates the socket path for `containerDirectory`.
    /// Throws ``SearchSocketError/pathTooLong(_:)`` when the container path
    /// cannot fit `sockaddr_un` — a configuration error, never silently
    /// truncated.
    public static func socketPath(inContainerDirectory containerDirectory: URL) throws -> String {
        let path = containerDirectory.appendingPathComponent(socketFileName).path
        let byteCount = path.utf8.count
        guard byteCount <= maxPathBytes else {
            throw SearchSocketError.pathTooLong(limit: maxPathBytes, actual: byteCount)
        }
        return path
    }

    /// Guard-file path (same length space as the socket path).
    public static func guardPath(inContainerDirectory containerDirectory: URL) -> String {
        containerDirectory.appendingPathComponent(guardFileName).path
    }

    // MARK: Framing

    /// Wraps `payload` in the length-prefixed frame.
    public static func framed(_ payload: Data) -> Data {
        var frame = Data(capacity: payload.count + lengthPrefixBytes)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Incremental parser for the framed stream. Feed it every chunk read off
    /// the socket; it hands back exactly one payload when a full frame has
    /// arrived. Bounds: the header fits in 4 buffered bytes, and an announced
    /// length above ``maxFrameSize`` throws immediately — a parser can never
    /// buffer more than one legal frame plus one in-flight chunk.
    public struct FrameParser {
        private var buffer = Data()
        private var announcedLength: UInt32?

        public init() {}

        /// True while a length prefix has been read but the payload is
        /// incomplete.
        public var isMidFrame: Bool { announcedLength != nil }

        public mutating func append(_ chunk: Data) {
            buffer.append(chunk)
        }

        /// Returns the next complete payload, or `nil` while the frame is
        /// still incomplete. Throws ``SearchSocketError/frameTooLarge(_:)``
        /// when the announced length exceeds the cap.
        public mutating func nextPayload() throws -> Data? {
            if announcedLength == nil {
                guard buffer.count >= lengthPrefixBytes else { return nil }
                var length: UInt32 = 0
                for byte in buffer.prefix(lengthPrefixBytes) {
                    length = (length << 8) | UInt32(byte)
                }
                buffer.removeFirst(lengthPrefixBytes)
                guard length <= maxFrameSize else {
                    throw SearchSocketError.frameTooLarge(length)
                }
                announcedLength = length
            }
            guard let length = announcedLength else { return nil }
            guard buffer.count >= Int(length) else { return nil }
            let payload = Data(buffer.prefix(Int(length)))
            buffer.removeFirst(Int(length))
            announcedLength = nil
            return payload
        }
    }
}

/// Errors surfaced by the search socket transport. These describe the PIPE
/// itself and are deliberately distinct from daemon application errors
/// (`SearchRPCError`), which travel INSIDE replies.
public enum SearchSocketError: Error, Equatable, Sendable {
    /// No live daemon: the socket file is absent (ENOENT) or refuses
    /// connections (ECONNREFUSED). The CLI maps this to explicit
    /// "the app is not running" guidance.
    case daemonNotRunning(path: String)
    /// Container path too long for `sockaddr_un.sun_path`.
    case pathTooLong(limit: Int, actual: Int)
    /// A frame length prefix exceeded ``SearchSocketWire/maxFrameSize``.
    case frameTooLarge(UInt32)
    /// The peer closed the connection before the frame completed.
    case incompleteFrame
    /// A phase exceeded its deadline (connect/send/recv/request read/handler).
    case timeout(operation: String)
    /// A POSIX call failed outside the mapped cases.
    case posix(operation: String, errno: Int32)
    /// Another live server already owns the container's guard flock.
    case serverAlreadyRunning(path: String)
    /// The accepted peer's effective uid differs from ours. Unreachable for
    /// a normal caller — the 0o700 directory already excludes other users —
    /// and treated as fail-closed when it somehow happens.
    case peerNotSameUser(uid: UInt32, peerUID: UInt32)
    /// Server misuse: `start()` after `stop()` (stop is terminal).
    case serverStopped
    /// Server misuse: `start()` on an already running server.
    case serverAlreadyStarted
}

extension SearchSocketError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            // The explicit fail-fast contract (plans/cli-domain-commands.md):
            // app closed ⇒ socket unlinked ⇒ every domain command names the
            // cause. Never imply "no wiki exists".
            return "the wikid daemon is not running — launch the app"
        case .pathTooLong(let limit, let actual):
            return "socket path is \(actual) bytes; sockaddr_un allows at most \(limit)"
        case .frameTooLarge(let length):
            return "frame of \(length) bytes exceeds the \(SearchSocketWire.maxFrameSize)-byte cap"
        case .incompleteFrame:
            return "the daemon closed the connection before the frame completed"
        case .timeout(let operation):
            return "socket \(operation) exceeded its deadline"
        case .posix(let operation, let errno):
            return "socket \(operation) failed (errno \(errno))"
        case .serverAlreadyRunning(let path):
            return "another daemon already owns the socket at \(path)"
        case .peerNotSameUser(let uid, let peerUID):
            return "peer uid \(peerUID) differs from ours \(uid); connection refused"
        case .serverStopped:
            return "the socket server is stopped and cannot restart"
        case .serverAlreadyStarted:
            return "the socket server is already running"
        }
    }

    /// True when the failure is the explicit "no live daemon" signal — the
    /// case every CLI command maps to exit 1 with the launch-the-app message.
    public var isDaemonNotRunning: Bool {
        if case .daemonNotRunning = self { return true }
        return false
    }
}

/// Low-level nonblocking socket routines shared by the client and the server.
/// Everything here is nonblocking: a would-block read/write becomes an await
/// on a one-shot Dispatch source raced against a deadline timer, so no
/// cooperative-pool thread ever parks on socket I/O.
public enum SearchSocketIO {

    /// Outcome of one nonblocking `recv`.
    public enum Recv: Sendable {
        case data(Data)
        /// Orderly EOF from the peer.
        case eof
        /// No bytes available yet (EAGAIN/EINTR) — await readiness and retry.
        case again
        /// A recv error outside the routine cases (e.g. ECONNRESET).
        case failed(SearchSocketError)
    }

    // MARK: Socket setup

    /// Creates a nonblocking AF_UNIX stream socket.
    public static func makeNonBlockingSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SearchSocketError.posix(operation: "socket", errno: errno)
        }
        do {
            try setNonBlocking(fd: fd)
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    public static func setNonBlocking(fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw SearchSocketError.posix(operation: "fcntl(F_GETFL)", errno: errno)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SearchSocketError.posix(operation: "fcntl(F_SETFL)", errno: errno)
        }
    }

    /// Binds `fd` to `path` (already length-validated), listens with
    /// `backlog`, and chmods the socket file to 0o600. The chmod failure
    /// THROWS: bind(2) on a filesystem socket applies the umask (typically
    /// leaving the file world-readable), and a looser socket would undercut
    /// the documented threat model.
    public static func bindListenAndHarden(fd: Int32, path: String, backlog: Int32) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= SearchSocketWire.maxPathBytes else {
            throw SearchSocketError.pathTooLong(
                limit: SearchSocketWire.maxPathBytes, actual: pathBytes.count)
        }
        let bindResult: Int32 = withUnsafeMutablePointer(to: &addr) { pointer in
            // Copy the validated path into sun_path; the trailing bytes stay
            // zeroed because sockaddr_un() is zero-initialized.
            withUnsafeMutableBytes(of: &pointer.pointee.sun_path) { destination in
                destination.copyBytes(from: pathBytes)
            }
            return withUnsafePointer(to: pointer.pointee) { socketAddress in
                socketAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard bindResult == 0 else {
            throw SearchSocketError.posix(operation: "bind", errno: errno)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            unlink(path)
            throw SearchSocketError.posix(operation: "chmod(socket, 0600)", errno: code)
        }
        guard listen(fd, backlog) == 0 else {
            throw SearchSocketError.posix(operation: "listen", errno: errno)
        }
    }

    /// Connects a fresh nonblocking socket to `path` and returns it.
    /// ENOENT/ECONNREFUSED/ENOTSOCK map to
    /// ``SearchSocketError/daemonNotRunning(path:)`` — the explicit "the app
    /// is not running" signal. ENOTSOCK covers a non-socket file left at the
    /// path. EINPROGRESS awaits writability (raced against `deadline`) and
    /// then checks SO_ERROR.
    public static func connectSocket(path: String, deadline: Date) async throws -> Int32 {
        let fd = try makeNonBlockingSocket()
        do {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            guard pathBytes.count <= SearchSocketWire.maxPathBytes else {
                throw SearchSocketError.pathTooLong(
                    limit: SearchSocketWire.maxPathBytes, actual: pathBytes.count)
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { destination in
                destination.copyBytes(from: pathBytes)
            }
            var connectErrno: Int32 = 0
            let connected: Int32 = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    var result: Int32 = -1
                    repeat {
                        result = connect(
                            fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                        if result == -1 { connectErrno = errno }
                    } while result == -1 && connectErrno == EINTR
                    return result
                }
            }
            if connected == 0 { return fd }
            switch connectErrno {
            case EINPROGRESS:
                try await awaitReady(
                    fd: fd, writable: true, deadline: deadline, operation: "connect")
                var soError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size) == 0 else {
                    throw SearchSocketError.posix(
                        operation: "getsockopt(SO_ERROR)", errno: errno)
                }
                guard soError == 0 else {
                    throw connectFailure(errno: soError, path: path)
                }
                return fd
            default:
                throw connectFailure(errno: connectErrno, path: path)
            }
        } catch {
            close(fd)
            throw error
        }
    }

    private static func connectFailure(errno: Int32, path: String) -> SearchSocketError {
        switch errno {
        // ENOTSOCK: a non-socket file occupies the path — no daemon is
        // listening either way.
        case ENOENT, ECONNREFUSED, ENOTSOCK:
            return .daemonNotRunning(path: path)
        default:
            return .posix(operation: "connect", errno: errno)
        }
    }

    // MARK: Readiness + transfer

    /// Awaits socket readiness (readable or writable) with a hard deadline.
    /// One-shot Dispatch source raced against a one-shot timer; exactly one
    /// settles the continuation, and BOTH dispatch objects are cancelled at
    /// settle time. Task cancellation settles the wait too — callers that
    /// hold a readiness wait unwind when their task is cancelled.
    public static func awaitReady(
        fd: Int32,
        writable: Bool,
        deadline: Date,
        operation: String
    ) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw SearchSocketError.timeout(operation: operation)
        }
        let box = ReadinessBox()
        _ = try await withTaskCancellationHandler {
            try await readinessValue(
                box: box,
                fd: fd,
                writable: writable,
                remaining: remaining,
                operation: operation)
        } onCancel: {
            box.settle(CancellationError())
        }
    }

    /// The continuation frame of ``awaitReady``, split into a named function:
    /// nesting the continuation directly inside the cancellation handler made
    /// the overload set ambiguous to the type checker.
    private static func readinessValue(
        box: ReadinessBox,
        fd: Int32,
        writable: Bool,
        remaining: TimeInterval,
        operation: String
    ) async throws -> Bool {
        // Unsafe variant: the ReadinessBox guarantees resume-at-most-once and
        // every wait is deadline-bounded; the checked wrapper's misuse
        // detection is redundant here and its overload set is ambiguous in
        // this module's SDK. The closure body delegates to a plain function —
        // type-checking the dispatch-source setup inside the closure crashed
        // the compiler's diagnostic machinery.
        try await withUnsafeThrowingContinuation {
            (continuation: UnsafeContinuation<Bool, Error>) in
            armReadiness(
                box: box,
                continuation: continuation,
                fd: fd,
                writable: writable,
                remaining: remaining,
                operation: operation)
        }
    }

    /// Arms the one-shot readiness source and deadline timer for one wait.
    private static func armReadiness(
        box: ReadinessBox,
        continuation: UnsafeContinuation<Bool, Error>,
        fd: Int32,
        writable: Bool,
        remaining: TimeInterval,
        operation: String
    ) {
        let queue = DispatchQueue(label: "org.sockpuppet.wiki.search-socket.ready")
        // if/else, not a ternary: coercing the two concrete DispatchSource
        // types through the protocol existential in a ternary crashes the
        // type checker's diagnostic machinery on this toolchain.
        let source: DispatchSourceProtocol
        if writable {
            source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        } else {
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        guard box.attach(continuation: continuation, source: source, timer: timer) else {
            // Cancelled before arming; the continuation already ran.
            return
        }
        source.setEventHandler { box.settle(nil) }
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler {
            box.settle(SearchSocketError.timeout(operation: operation))
        }
        source.resume()
        timer.resume()
    }

    /// Resume-once carrier for a readiness wait (same shape as
    /// `SearchReplyBox` in DaemonSearchClient): readiness, the deadline
    /// timer, or task cancellation settles the box exactly once; stragglers
    /// are absorbed and the dispatch objects are cancelled at settle time.
    // NSLock protects the only mutable state and the continuation resumes at
    // most once.
    // swiftlint:disable:next unchecked_sendable
    private final class ReadinessBox: @unchecked Sendable {

        private enum Payload {
            case idle
            case settled(Error?)
            case waiting(UnsafeContinuation<Bool, Error>)
        }

        private let lock = NSLock()
        private var payload: Payload = .idle
        private var source: DispatchSourceProtocol?
        private var timer: DispatchSourceProtocol?

        init() {}

        /// Arms the box. Returns false when the box had ALREADY settled (the
        /// caller must skip arming its dispatch objects); in that case the
        /// stored error is delivered to `continuation` here.
        func attach(
            continuation: UnsafeContinuation<Bool, Error>,
            source: DispatchSourceProtocol,
            timer: DispatchSourceProtocol
        ) -> Bool {
            lock.lock()
            self.source = source
            self.timer = timer
            var earlyError: Error?
            switch payload {
            case .idle:
                payload = .waiting(continuation)
                lock.unlock()
                return true
            case .settled(let error):
                earlyError = error
            case .waiting:
                // One box serves one waiter; a second attach is a caller bug.
                earlyError = SearchSocketError.posix(operation: "readiness re-entry", errno: 0)
            }
            lock.unlock()
            if let earlyError {
                continuation.resume(throwing: earlyError)
            } else {
                continuation.resume(returning: true)
            }
            return false
        }

        func settle(_ error: Error?) {
            lock.lock()
            var continuation: UnsafeContinuation<Bool, Error>?
            switch payload {
            case .idle:
                payload = .settled(error)
            case .settled:
                break
            case .waiting(let waiting):
                payload = .settled(error)
                continuation = waiting
            }
            let source = source
            let timer = timer
            lock.unlock()
            source?.cancel()
            timer?.cancel()
            if let continuation {
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// One nonblocking `recv` into a fresh scratch chunk.
    public static func recvOnce(fd: Int32) -> Recv {
        var chunk = Data(count: SearchSocketWire.readChunkSize)
        let received = chunk.withUnsafeMutableBytes { buffer in
            recv(fd, buffer.baseAddress, buffer.count, 0)
        }
        if received > 0 {
            chunk.removeSubrange(received..<chunk.count)
            return .data(chunk)
        }
        if received == 0 { return .eof }
        let code = errno
        if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { return .again }
        return .failed(.posix(operation: "recv", errno: code))
    }

    /// Writes the whole `bytes` under `deadline`, awaiting writability on
    /// EAGAIN. Never blocks a cooperative-pool thread: the only suspension
    /// is the continuation-based readiness wait.
    public static func sendAll(fd: Int32, bytes: Data, deadline: Date) async throws {
        var offset = 0
        while offset < bytes.count {
            try checkDeadline(deadline, operation: "send")
            let sent = bytes[offset...].withUnsafeBytes { buffer -> Int in
                send(fd, buffer.baseAddress, buffer.count, 0)
            }
            if sent > 0 {
                offset += sent
                continue
            }
            let code = errno
            if code == EINTR { continue }
            guard code == EAGAIN || code == EWOULDBLOCK else {
                throw SearchSocketError.posix(operation: "send", errno: code)
            }
            try await awaitReady(fd: fd, writable: true, deadline: deadline, operation: "send")
        }
    }

    public static func checkDeadline(_ deadline: Date, operation: String) throws {
        guard deadline > Date() else {
            throw SearchSocketError.timeout(operation: operation)
        }
    }

    /// The peer's effective uid via getpeereid(2); nil when the syscall
    /// fails (fail closed at the call site).
    public static func peerUID(fd: Int32) -> UInt32? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return UInt32(uid)
    }
}
#endif
