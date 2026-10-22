#if os(macOS)
import Dispatch
import Foundation
import WikiDaemonContract
import WikiFSCore

/// Daemon-side listener for the CLI search socket transport.
///
/// The daemon is the sole index owner; this server publishes the existing
/// `WikiDaemon.searchData(request:) async -> Data` handler on a bounded local
/// AF_UNIX socket so the standalone `wikictl` binary — which cannot open an
/// app-only `NSXPCConnection` — can search. Search-only: nothing on this
/// transport mutates wiki state.
///
/// Lifecycle (owned by the daemon boot code):
///
///     let server = try DaemonSearchSocketServer(
///         containerDirectory: container,
///         handler: { [daemon] request in await daemon.searchData(request: request) })
///     try server.start()   // after the daemon is ready to serve
///     server.stop()        // before daemon shutdown (stop is terminal)
///
/// Security & bounds contract:
/// - Socket file `wikid-search.sock` in `containerDirectory`, chmod 0o600;
///   the container directory is tightened to 0o700 when looser.
/// - getpeereid(2) on every accepted fd: any peer whose effective uid is not
///   ours is dropped BEFORE a byte is read. Same-user, read-only search is
///   the documented trust boundary (see `SearchSocketWire`).
/// - A process-lifetime exclusive flock on `wikid-search.lock` is taken in
///   `init`, BEFORE the stale-socket unlink in `start()`. A second live
///   server fails at init with
///   ``SearchSocketError/serverAlreadyRunning(path:)`` and can never unlink
///   a served socket; a socket file that outlives its process is provably
///   ownerless (the flock died with it) and safe to remove.
/// - One request per connection, frames capped at
///   ``SearchSocketWire/maxFrameSize``, every phase deadline-bounded:
///   request read (``Limits/requestReadTimeout``), handler
///   (``Limits/handlerTimeout`` — deliberately above the CLI's 30 s outer
///   bound so a healthy call never trips it), reply write
///   (``Limits/replyWriteTimeout``). Nothing can pin an fd or a task forever.
/// - All fd I/O is nonblocking; waits ride one-shot Dispatch sources raced
///   against timers, so no cooperative-pool thread ever parks on the socket.
///
/// Residual note: an fd number can be reused between one of this
/// connection's state checks and its next syscall. Every fd touch re-checks
/// the connection phase under lock, and `stop()` cancels the accept source
/// before any fd closes, so the exposure is confined to a same-user peer
/// receiving a protocol-level rejection — never memory unsafety, never a
/// write crossing users.
///
// stateLock serializes every mutable field (phase, fds, connection map);
// the handler closure is immutable after init.
// swiftlint:disable:next unchecked_sendable
public final class DaemonSearchSocketServer: @unchecked Sendable {

    /// Deadline budget for one accepted connection's phases. One place to
    /// tune; each constant documents why it is what it is.
    private enum Limits {
        /// accept(2) backlog. CLI bursts are small; 16 absorbs a burst of
        /// concurrent queries without a second listener.
        static let listenBacklog: Int32 = 16
        /// Cap on simultaneously connected clients; excess accepts are
        /// closed immediately so a runaway client cannot pin fds.
        static let maxConcurrentConnections = 64
        /// A request frame must arrive fully within this window of accept.
        static let requestReadTimeout: TimeInterval = 30
        /// The handler must answer within this. DELIBERATELY above the CLI's
        /// 30 s outer timeout: a healthy call never trips it; a wedged
        /// handler only delays fd reclaim by this one bound.
        static let handlerTimeout: TimeInterval = 60
        /// The framed reply must flush within this window.
        static let replyWriteTimeout: TimeInterval = 30
    }

    private enum LifecycleState {
        case initialized
        case running
        case stopped
    }

    /// Serializes the accept(2) drain. Shared by instances; handlers are
    /// tiny and never block.
    private static let acceptQueue = DispatchQueue(
        label: "org.sockpuppet.wiki.search-socket.accept")

    // Immutable after init.
    public let socketPath: String
    private let containerPath: String
    private let guardPath: String
    private let handler: @Sendable (Data) async -> Data

    /// Locked mutable state. Lock ordering: NEVER hold `stateLock` while
    /// calling into a `Connection`, and never hold a connection's lock while
    /// calling into the server — each direction takes its lock alone.
    // swiftlint:disable:next unchecked_sendable
    private let stateLock = NSLock()
    private var state: LifecycleState = .initialized
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var guardFD: Int32 = -1
    private var connections: [Int32: Connection] = [:]

    /// Takes the process-lifetime guard flock. Throws
    /// ``SearchSocketError/serverAlreadyRunning(path:)`` when another live
    /// server owns this container's socket, or a POSIX error when the guard
    /// file cannot be opened or flocked. Does NOT touch the socket path —
    /// stale cleanup happens in `start()`, only while the guard is held.
    public init(
        containerDirectory: URL,
        handler: @escaping @Sendable (Data) async -> Data
    ) throws {
        self.socketPath = try SearchSocketWire.socketPath(inContainerDirectory: containerDirectory)
        self.containerPath = containerDirectory.path
        self.guardPath = SearchSocketWire.guardPath(inContainerDirectory: containerDirectory)
        self.handler = handler

        // The guard file lives in the container; create the directory so a
        // fresh container works. Permission tightening happens in start().
        try FileManager.default.createDirectory(
            at: containerDirectory, withIntermediateDirectories: true)

        let fd = open(guardPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SearchSocketError.posix(operation: "open(guard)", errno: errno)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw SearchSocketError.serverAlreadyRunning(path: socketPath)
            }
            throw SearchSocketError.posix(operation: "flock(guard)", errno: code)
        }
        guardFD = fd
    }

    deinit {
        // Best-effort teardown for a caller that drops a live server without
        // stop(); the normal path is an explicit stop before daemon shutdown.
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD) }
        for connection in connections.values {
            connection.finish(reason: "server deallocated")
        }
        if guardFD >= 0 { close(guardFD) }
    }

    /// Binds, listens, and starts accepting. Call after the daemon is ready
    /// to serve search requests. `start()` is once-only: after `stop()` it
    /// throws ``SearchSocketError/serverStopped``; a second `start()` on a
    /// running server throws ``SearchSocketError/serverAlreadyStarted``.
    public func start() throws {
        // Tighten the directory when looser than 0o700 (defense in depth;
        // the getpeereid check remains the gate). Failure only logs: a
        // permissions-stubborn mount must not block search.
        Self.tightenDirectoryPermissionsIfLoose(path: containerPath)

        // The state check, stale-socket cleanup, and bind happen under ONE
        // lock hold: a concurrent second start() must never reach the
        // stale-unlink while a live listener of ours exists.
        stateLock.lock()
        let source: DispatchSourceRead
        do {
            switch state {
            case .running:
                throw SearchSocketError.serverAlreadyStarted
            case .stopped:
                throw SearchSocketError.serverStopped
            case .initialized:
                break
            }

            // Stale-socket cleanup — safe BECAUSE init already owns the guard
            // flock and no listener of ours is bound yet: any socket file
            // still at this path outlived its process, and a live server
            // would have failed this init on the flock.
            if FileManager.default.fileExists(atPath: socketPath) {
                do {
                    try FileManager.default.removeItem(atPath: socketPath)
                } catch {
                    DebugLog.store(
                        "wikid: could not remove stale search socket \(socketPath): \(error)")
                    throw SearchSocketError.posix(operation: "unlink(stale socket)", errno: errno)
                }
            }

            let fd: Int32
            do {
                fd = try SearchSocketIO.makeNonBlockingSocket()
                try SearchSocketIO.bindListenAndHarden(
                    fd: fd, path: socketPath, backlog: Limits.listenBacklog)
            } catch {
                state = .stopped
                throw error
            }
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.acceptQueue)
            listenFD = fd
            acceptSource = source
            state = .running
        } catch {
            stateLock.unlock()
            throw error
        }
        stateLock.unlock()
        source.setEventHandler { [weak self] in self?.drainAccepts() }
        source.resume()
    }

    /// Terminal teardown: stops accepting, closes every live connection
    /// (in-flight reply writes unwind through their cancellation-aware
    /// readiness waits), unlinks the socket file, and releases the guard
    /// flock. Idempotent; the instance cannot restart afterwards. Call
    /// before daemon shutdown.
    public func stop() {
        stateLock.lock()
        guard state != .stopped else {
            stateLock.unlock()
            return
        }
        state = .stopped
        let acceptSource = acceptSource
        self.acceptSource = nil
        let listenFD = listenFD
        self.listenFD = -1
        let connections = Array(self.connections.values)
        self.connections.removeAll()
        stateLock.unlock()

        // No new accepts before any fd closes: this closes the fd-reuse
        // window while the connections drain.
        acceptSource?.cancel()
        if listenFD >= 0 { close(listenFD) }
        for connection in connections {
            connection.finish(reason: "server stopped")
        }

        // The socket file is ours by construction of the guard: unlink it so
        // a CLI between daemons sees ENOENT (a clean "not running") instead
        // of a refusal against a dead inode.
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                // Best-effort: a leftover socket file is stale-cleanup fuel
                // for the next start(), so failing to remove one is visible
                // but not fatal.
                DebugLog.store("wikid: could not unlink search socket \(socketPath): \(error)")
            }
        }

        stateLock.lock()
        let guardFD = guardFD
        self.guardFD = -1
        stateLock.unlock()
        if guardFD >= 0 { close(guardFD) } // releases the flock
    }

    // MARK: - Accepts

    private func drainAccepts() {
        stateLock.lock()
        let listenFD = listenFD
        stateLock.unlock()
        guard listenFD >= 0 else { return }
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                break // EAGAIN: drained; other errors re-fire with the next event
            }
            acceptConnection(fd: clientFD)
        }
    }

    private func acceptConnection(fd: Int32) {
        // Same-user gate BEFORE any byte is read (documented threat model:
        // same-user, read-only search; directory + socket permissions are
        // the outer shells, getpeereid is the explicit check).
        guard let peerUID = SearchSocketIO.peerUID(fd: fd), peerUID == UInt32(geteuid()) else {
            DebugLog.store("wikid: search socket rejected non-same-user peer on fd \(fd)")
            close(fd)
            return
        }
        do {
            try SearchSocketIO.setNonBlocking(fd: fd)
        } catch {
            DebugLog.store("wikid: search socket rejected fd \(fd): \(error)")
            close(fd)
            return
        }
        stateLock.lock()
        guard state == .running, connections.count < Limits.maxConcurrentConnections else {
            // stop() raced the accept, or the connection cap is full: drop.
            stateLock.unlock()
            close(fd)
            return
        }
        let connection = Connection(
            fd: fd,
            server: self,
            handler: handler,
            requestReadTimeout: Limits.requestReadTimeout,
            handlerTimeout: Limits.handlerTimeout,
            replyWriteTimeout: Limits.replyWriteTimeout)
        connections[fd] = connection
        stateLock.unlock()
        connection.begin()
    }

    fileprivate func forgetConnection(_ connection: Connection) {
        stateLock.lock()
        if connections[connection.fd] === connection {
            connections.removeValue(forKey: connection.fd)
        }
        stateLock.unlock()
    }

    // MARK: - Helpers

    private static func tightenDirectoryPermissionsIfLoose(path: String) {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            DebugLog.store("wikid: search socket directory stat failed (continuing): \(error)")
            return
        }
        guard let raw = attributes[.posixPermissions] as? NSNumber else { return }
        let mode = raw.uint32Value
        guard mode & 0o077 != 0 else { return } // already owner-only
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path)
            DebugLog.store(
                "wikid: tightened search socket directory \(path) from \(String(mode, radix: 8)) to 700")
        } catch {
            DebugLog.store(
                "wikid: could not tighten search socket directory \(path) (continuing): \(error)")
        }
    }
}

/// One accepted client connection: exactly one framed request in, one framed
/// reply out, close. Byte buffering lives on the connection's private queue
/// (Dispatch source handlers); phase transitions live under `stateLock`.
// NSLock guards the phase machine; the read buffer is confined to `queue`.
// swiftlint:disable:next unchecked_sendable
private final class Connection: @unchecked Sendable {

    private enum Phase {
        case readingRequest
        case processing
        case writingReply
        case finished
    }

    fileprivate let fd: Int32
    private weak var server: DaemonSearchSocketServer?
    private let handler: @Sendable (Data) async -> Data
    private let requestReadTimeout: TimeInterval
    private let handlerTimeout: TimeInterval
    private let replyWriteTimeout: TimeInterval

    /// All buffer mutations and recv calls happen on this queue.
    private let queue = DispatchQueue(
        label: "org.sockpuppet.wiki.search-socket.connection")

    private let stateLock = NSLock()
    private var phase: Phase = .readingRequest
    private var readSource: DispatchSourceRead?
    private var readTimer: DispatchSourceTimer?
    // Read-side buffer state, confined to `queue`.
    private var parser = SearchSocketWire.FrameParser()
    private var readDeadline = Date.distantFuture

    init(
        fd: Int32,
        server: DaemonSearchSocketServer,
        handler: @escaping @Sendable (Data) async -> Data,
        requestReadTimeout: TimeInterval,
        handlerTimeout: TimeInterval,
        replyWriteTimeout: TimeInterval
    ) {
        self.fd = fd
        self.server = server
        self.handler = handler
        self.requestReadTimeout = requestReadTimeout
        self.handlerTimeout = handlerTimeout
        self.replyWriteTimeout = replyWriteTimeout
    }

    /// Arms the read source and the request-read deadline timer. Called once,
    /// after the server registered the connection.
    func begin() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainReads() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + requestReadTimeout)
        timer.setEventHandler { [weak self] in self?.enforceReadDeadline() }
        stateLock.lock()
        guard phase != .finished else {
            stateLock.unlock()
            return
        }
        // Published under the lock: drainReads reads it from another thread
        // after re-acquiring the same lock.
        readDeadline = Date().addingTimeInterval(requestReadTimeout)
        readSource = source
        readTimer = timer
        stateLock.unlock()
        source.resume()
        timer.resume()
        // stop() may have raced the resume: retire the sources immediately.
        stateLock.lock()
        let raced = phase == .finished
        stateLock.unlock()
        if raced {
            source.cancel()
            timer.cancel()
        }
    }

    // MARK: Request read (queue-confined)

    private func drainReads() {
        while isActive() {
            switch SearchSocketIO.recvOnce(fd: fd) {
            case .data(let chunk):
                parser.append(chunk)
                do {
                    if let request = try parser.nextPayload() {
                        startProcessing(request)
                        return
                    }
                } catch {
                    finish(reason: "oversized request frame: \(error)")
                    return
                }
            case .eof:
                finish(reason: "peer closed before the request completed")
                return
            case .again:
                return
            case .failed(let error):
                finish(reason: "recv failed: \(error)")
                return
            }
            do {
                try SearchSocketIO.checkDeadline(readDeadline, operation: "request read")
            } catch {
                finish(reason: "request read deadline exceeded")
                return
            }
        }
    }

    private func enforceReadDeadline() {
        stateLock.lock()
        let stillReading = phase == .readingRequest
        stateLock.unlock()
        guard stillReading else { return }
        finish(reason: "request read deadline exceeded")
    }

    private func isActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return phase == .readingRequest
    }

    // MARK: Handler + reply

    /// The handler budget for THIS request: decode the domain envelope's
    /// family/operation (a decode failure keeps `fallback` — the standard
    /// bound) and look up the per-endpoint table in the shared contract
    /// (`DaemonDomainBudgets`).
    private static func perEndpointBudget(
        for request: Data, fallback: TimeInterval
    ) -> TimeInterval {
        let envelope: DaemonDomainRequest
        do {
            envelope = try JSONDecoder().decode(DaemonDomainRequest.self, from: request)
        } catch {
            return fallback
        }
        return DaemonDomainBudgets.handlerTimeout(
            family: envelope.family, operation: envelope.operation)
    }

    /// The frame is complete: race the handler against its deadline so a
    /// never-replying handler cannot pin the fd past one bound.
    private func startProcessing(_ request: Data) {
        stateLock.lock()
        guard phase == .readingRequest else {
            stateLock.unlock()
            return
        }
        phase = .processing
        let readSource = readSource
        self.readSource = nil
        let readTimer = readTimer
        self.readTimer = nil
        stateLock.unlock()
        readSource?.cancel()
        readTimer?.cancel()

        let box = ReplyRaceBox()
        let handler = handler
        // Per-endpoint handler budget (Phase 4, plans/cli-domain-commands.md
        // §"Long-running operations"): the envelope's family/operation names
        // the budget — long-running operations (admin sweeps, workspace
        // merge/reap) get the elevated ceiling; everything else keeps the
        // socket's standard bound. An undecodable frame keeps the standard
        // bound too (the dispatcher will reject it as invalidRequest long
        // before any budget matters).
        let handlerTimeout = Self.perEndpointBudget(
            for: request, fallback: handlerTimeout)
        let producer = Task.detached(priority: .userInitiated) {
            box.fulfill(await handler(request))
        }
        box.register(producer: producer)
        Task.detached(priority: .utility) {
            // The sleeper is never cancelled by us, so this settles at the
            // deadline at the latest (a cancel would only shorten it). A
            // cancelled sleep is the correct expiry trigger anyway, so the
            // error itself is meaningless here.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .seconds(handlerTimeout))
            box.expire()
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let reply = await box.wait()
            // On the timeout leg, ask the orphaned handler task to wind down
            // (best-effort: `searchData` is cooperative-cancellation-agnostic
            // and completes on its own; it holds no fd).
            if reply == nil {
                box.cancelProducer()
            }
            await self?.deliver(reply)
        }
    }

    private func deliver(_ reply: Data?) async {
        guard transitionToWriting() else { return }

        guard let reply else {
            // Handler deadline expired: no reply exists to send. The fd
            // closes here; the client's outer timeout has usually fired
            // already, so this surfaces client-side as its own timeout.
            finish(reason: "handler deadline exceeded")
            return
        }
        await writeReply(reply)
    }

    /// Synchronous phase transition: `.processing` → `.writingReply`. Returns
    /// false when `stop()` already finished the connection. Locking stays out
    /// of async contexts (NSLock is unavailable there).
    private func transitionToWriting() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard phase == .processing else { return false }
        phase = .writingReply
        return true
    }

    private func writeReply(_ reply: Data) async {
        guard reply.count <= Int(SearchSocketWire.maxFrameSize) else {
            DebugLog.store(
                "wikid: search reply of \(reply.count) bytes exceeds the frame cap; dropping the connection")
            finish(reason: "reply exceeds frame cap")
            return
        }
        let deadline = Date().addingTimeInterval(replyWriteTimeout)
        do {
            try await SearchSocketIO.sendAll(
                fd: fd, bytes: SearchSocketWire.framed(reply), deadline: deadline)
        } catch {
            finish(reason: "reply write failed: \(error)")
            return
        }
        finish(reason: nil)
    }

    // MARK: Teardown

    /// Idempotent terminal transition. A non-nil `reason` logs a transport
    /// failure; nil logs clean completion. Cancel-before-close (Dispatch
    /// contract: deschedule a source before its fd closes).
    fileprivate func finish(reason: String?) {
        stateLock.lock()
        guard phase != .finished else {
            stateLock.unlock()
            return
        }
        phase = .finished
        let readSource = readSource
        self.readSource = nil
        let readTimer = readTimer
        self.readTimer = nil
        stateLock.unlock()

        if let reason {
            DebugLog.store("wikid: search socket connection \(fd) ended: \(reason)")
        }
        readSource?.cancel()
        readTimer?.cancel()
        close(fd)
        server?.forgetConnection(self)
    }

    deinit {
        // Sources must already be cancelled by finish(); the server's deinit
        // and stop() both route through it.
    }
}

/// One-shot `Data?` carrier raced between the handler task and the handler
/// deadline sleeper (same resume-once shape as `SearchReplyBox` in
/// DaemonSearchClient): the reply or the deadline settles the box exactly
/// once; stragglers are absorbed.
// NSLock protects the only mutable field and the continuation resumes at
// most once.
// swiftlint:disable:next unchecked_sendable
private final class ReplyRaceBox: @unchecked Sendable {

    private enum Payload {
        case idle
        case waiting(CheckedContinuation<Data?, Never>)
        case settled(Data?)
    }

    private let lock = NSLock()
    private var payload: Payload = .idle
    private var producer: Task<Void, Never>?

    func fulfill(_ data: Data) {
        settle(data)
    }

    func expire() {
        settle(nil)
    }

    /// Remember the producer task so the timeout leg can cancel it.
    func register(producer: Task<Void, Never>) {
        lock.lock()
        self.producer = producer
        lock.unlock()
    }

    func cancelProducer() {
        lock.lock()
        let producer = producer
        lock.unlock()
        producer?.cancel()
    }

    private func settle(_ data: Data?) {
        lock.lock()
        let continuation: CheckedContinuation<Data?, Never>?
        switch payload {
        case .idle:
            payload = .settled(data)
            continuation = nil
        case .waiting(let waiting):
            payload = .settled(data)
            continuation = waiting
        case .settled:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: data)
    }

    func wait() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            lock.lock()
            switch payload {
            case .idle:
                payload = .waiting(continuation)
                lock.unlock()
            case .settled(let data):
                lock.unlock()
                continuation.resume(returning: data)
            case .waiting:
                // One box serves one waiter; a second waiter is a caller bug.
                lock.unlock()
                continuation.resume(returning: nil)
            }
        }
    }
}
#endif
