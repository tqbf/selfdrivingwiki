#if os(macOS)
import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import WikiDaemonGRPCContract
import WikiFSTypes

/// The daemon's gRPC listener for the app–daemon contract.
///
/// Ownership + lifecycle contract (plans/app-daemon-protocol.md →
/// Protocol/app-daemon/README.md):
/// - The endpoint is a Unix domain socket at `g/s` under the App Group
///   container, inside a mode-0700 directory. NO TCP listener exists.
/// - A process-lifetime exclusive `flock` on `g/grpc.lock` is taken at init,
///   BEFORE any socket touch. A second live listener fails at init with
///   ``DaemonGRPCSocketError/serverAlreadyRunning(path:)`` and can never
///   unlink a served socket; a socket file that outlives its process is
///   provably ownerless (the flock died with it) and safe to remove.
/// - `start()` binds and serves. `waitUntilServing(timeout:)` reports when
///   the endpoint actually accepts — callers hand out the endpoint (and the
///   admission credential) only after readiness.
/// - `stop()` is the terminal teardown: stop accepting, wait for the server
///   task to wind down, run the revocation hook (session revocation + stream
///   termination + hub close), unlink the socket UNDER the guard, then
///   release the flock. Call before daemon shutdown.
///
/// All socket syscalls are nonblocking; nothing in this class parks a
/// cooperative thread on I/O (the serving loop lives on the transport's own
/// event loop group).
// All mutable state (lifecycle phase, guard fd, serving task) is
// covered by `stateLock`; the failure box carries its own lock.
// swiftlint:disable:next unchecked_sendable
public final class DaemonGRPCListener: @unchecked Sendable {

    private enum LifecycleState {
        case initialized
        case running
        case stopped
    }

    /// The declared transport bound for single messages (mirrors the XPC
    /// store transport's 4 MiB frame cap; receivers reject oversize with
    /// RESOURCE_EXHAUSTED per the contract's bounds rule).
    static let maxMessageBytes = 4 * 1024 * 1024

    /// Immutable after init.
    public let socketPath: String
    private let directoryPath: String
    private let provider: AppDaemonServiceProvider
    /// Runs after the serving task winds down, before unlink: the caller
    /// composes session revocation + stream termination + hub close here, so
    /// the ordering "revoke → await listener shutdown → unlink under guard →
    /// release" is enforced by construction.
    private let onShutdown: @Sendable () async -> Void
    /// Probe budget for ``waitUntilServing``.
    private let servingProbeInterval: Duration

    private let stateLock = NSLock()
    private var state: LifecycleState = .initialized
    private var guardFD: Int32 = -1
    private var serverTask: Task<Void, Never>?
    /// The serving task's failure (e.g. bind error), stored by the task and
    /// read by the readiness probe.
    private let serverFailure = FailureBox()

    /// A clean serve-loop exit, recorded in the failure box so isServing
    /// reflects ANY exit path, not just throws.
    private struct ServeExit: Error {}

    /// Lock-backed one-slot error carrier between the serving task and the
    /// readiness probe (first failure wins).
    // The single failure slot is covered by `lock`.
    // swiftlint:disable:next unchecked_sendable
    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: (any Error)?

        func set(_ error: any Error) {
            lock.lock()
            if failure == nil { failure = error }
            lock.unlock()
        }

        func get() -> (any Error)? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
    }

    /// Takes the process-lifetime guard flock. Throws
    /// ``DaemonGRPCSocketError/serverAlreadyRunning(path:)`` when another live
    /// listener owns this container's endpoint, or a POSIX error when the
    /// guard file cannot be opened or flocked. Does NOT touch the socket
    /// path — stale cleanup happens in `start()`, only while the guard is
    /// held.
    public init(
        containerDirectory: URL,
        provider: AppDaemonServiceProvider,
        onShutdown: @escaping @Sendable () async -> Void,
        servingProbeInterval: Duration = .milliseconds(20)
    ) throws {
        self.socketPath = try DaemonGRPCSocketPaths.socketPath(inContainer: containerDirectory)
        self.directoryPath = DaemonGRPCSocketPaths.directory(inContainer: containerDirectory).path
        self.provider = provider
        self.onShutdown = onShutdown
        self.servingProbeInterval = servingProbeInterval
        self.guardPath = DaemonGRPCSocketPaths.guardPath(inContainer: containerDirectory)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directoryPath, isDirectory: true),
            withIntermediateDirectories: true)

        let fd = open(guardPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw DaemonGRPCSocketError.posix(operation: "open(guard)", errno: errno)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw DaemonGRPCSocketError.serverAlreadyRunning(path: socketPath)
            }
            throw DaemonGRPCSocketError.posix(operation: "flock(guard)", errno: code)
        }
        guardFD = fd
    }

    private let guardPath: String

    deinit {
        // Best-effort teardown for a dropped live listener; the normal path
        // is an explicit stop() before daemon shutdown. The guard fd is
        // closed ONLY when no teardown owns it: beginTeardown takes the fd
        // out of the instance, so a running teardown keeps responsibility
        // (early release here would drop the flock before its unlink ran).
        serverTask?.cancel()
        stateLock.lock()
        let ownsGuard = stopTask == nil && guardFD >= 0
        let fd = guardFD
        guardFD = -1
        stateLock.unlock()
        if ownsGuard && fd >= 0 { close(fd) }
    }

    /// Binds and starts serving. Once-only (like the search-socket server).
    /// The serving loop runs on the transport's event loop; readiness is
    /// reported by ``waitUntilServing(timeout:)``.
    public func start() throws {
        try Self.tightenDirectoryPermissionsIfLoose(path: directoryPath)

        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .running:
            throw DaemonGRPCSocketError.serverAlreadyStarted
        case .stopped:
            throw DaemonGRPCSocketError.serverStopped
        case .initialized:
            break
        }

        // Stale-socket cleanup — safe BECAUSE init already owns the guard
        // flock: any socket file still at this path outlived its process, and
        // a live listener would have failed this init on the flock.
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                throw DaemonGRPCSocketError.posix(operation: "unlink(stale socket)", errno: errno)
            }
        }

        // The transport default already enforces the declared bound: a
        // single message must stay under 4 MiB (mirrors the XPC store
        // transport's frame cap; see Protocol/app-daemon/README.md §bounds).
        // No TCP, no TLS: plaintext loopback over the private socket only.
        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext)
        let server = GRPCServer(transport: transport, services: [provider])
        let failureBox = serverFailure
        let task = Task<Void, Never> {
            do {
                try await server.serve()
            } catch {
                // start() returns before bind completes; the probe reads
                // this failure (e.g. EADDRINUSE against a raced sibling)
                // instead of waiting out its budget.
                failureBox.set(error)
            }
            // A CLEAN serve exit is recorded too: isServing must go false
            // when the loop stops for ANY reason, or admission would mint
            // sessions for a dead endpoint.
            failureBox.set(ServeExit())
        }
        serverTask = task
        state = .running
    }

    /// Wait until the endpoint accepts connections, or fail with the serving
    /// task's error (bind failure) or a typed timeout. Callers must gate the
    /// XPC admission reply on this returning true.
    public func waitUntilServing(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            // Surface a serving-task failure (bind error) immediately.
            if let failure = serverFailure.get() { throw failure }
            if await Self.endpointAccepts(path: socketPath) { return }
            // A cancelled sleep only shortens the next check; the
            // deadline loop below is the actual bound.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: servingProbeInterval)
        }
        throw AppDaemonFailure(
            code: .unavailable,
            message: "gRPC endpoint did not become ready within \(timeout)")
    }

    /// Terminal teardown. Idempotent AND joinable: every caller awaits the
    /// same teardown. Order per the contract: stop accepting (cancel task)
    /// → revoke sessions + close streams (the onShutdown hook) → await the
    /// serving loop's exit → unlink the socket under the guard → release
    /// the flock. Locking stays out of async contexts — the state
    /// transition is a synchronous helper.
    public func stop() async {
        guard let teardown = beginTeardown() else { return }
        await teardown.value
    }

    /// The synchronous phase transition behind ``stop``: `.running` →
    /// `.stopped`, creating (once) and returning the teardown task. Returns
    /// the EXISTING teardown on repeat calls, so concurrent stoppers join
    /// instead of racing. The guard fd is TRANSFERRED to the teardown here
    /// (out of the instance), so teardown completion does not depend on
    /// the listener's lifetime.
    private func beginTeardown() -> Task<Void, Never>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let stopTask { return stopTask }
        guard state == .running else { return nil }
        state = .stopped
        let servingTask = serverTask
        serverTask = nil
        let guardFD = takeGuardFD()
        let failureBox = serverFailure
        let socketPath = socketPath
        let onShutdown = onShutdown
        let teardown = Task<Void, Never> {
            // 1. Stop accepting.
            servingTask?.cancel()
            // 2. Revoke sessions + close streams BEFORE awaiting the
            //    serving loop's exit (the contract's ordering).
            await onShutdown()
            // 3. Await the serving loop's exit.
            _ = await servingTask?.result
            _ = failureBox
            // 4. Unlink under the guard (the fd was transferred above —
            //    completion no longer depends on the listener instance);
            //    5. release the flock.
            if FileManager.default.fileExists(atPath: socketPath) {
                // Best-effort unlink under the guard: a leftover file is
                // next-start's stale fuel, logged but not fatal to shutdown.
                do {
                    try FileManager.default.removeItem(atPath: socketPath)
                } catch {
                    DebugLog.store(
                        "wikid: could not unlink gRPC socket \(socketPath): \(error)")
                }
            }
            if guardFD >= 0 { close(guardFD) } // releases the flock
        }
        stopTask = teardown
        return teardown
    }

    /// The memoized teardown task (nil until the first stop()).
    private var stopTask: Task<Void, Never>?

    /// True while the listener is in the `.running` state AND the serving
    /// task has not recorded a failure. Admission gates on this — a
    /// listener that stopped or whose serve loop died must not mint new
    /// sessions for a dead endpoint.
    public var isServing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state == .running && serverFailure.get() == nil
    }

    private func takeGuardFD() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let fd = guardFD
        guardFD = -1
        return fd
    }

    // MARK: - Probes

    /// True when a client can connect to the endpoint right now. A
    /// NONBLOCKING connect on a throwaway socket so a wedged listener
    /// cannot park the probing thread; the descriptor closes on EVERY path
    /// (defer), and an EINPROGRESS completion is resolved with a bounded
    /// SO_ERROR poll rather than assumed.
    public static func endpointAccepts(path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            // The descriptor closes on EVERY path — earlier versions
            // leaked it on success/refusal/overlong-path.
            defer { close(fd) }
            // Nonblocking BEFORE connect so a wedged peer cannot park this
            // probe thread; connect then returns EINPROGRESS immediately.
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                return false
            }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { destination in
                guard let base = destination.baseAddress else { return }
                base.copyMemory(from: bytes, byteCount: bytes.count)
            }
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return true }
            // Nonblocking connect: EINPROGRESS means completion is pending.
            // An immediate SO_ERROR read cannot establish that (it may
            // still report EINPROGRESS); poll with a ~1s budget.
            guard errno == EINPROGRESS else { return errno == EISCONN }
            for _ in 0 ..< 100 {
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                if soError == 0 { return true }
                if soError != EINPROGRESS { return false }
                usleep(10_000)
            }
            return false
        }.value
    }

    /// Tighten the private directory to 0700 when looser (defense in depth;
    /// credentials and socket live here).
    static func tightenDirectoryPermissionsIfLoose(path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let raw = attributes[.posixPermissions] as? NSNumber else { return }
        let mode = raw.uint32Value
        guard mode & 0o077 != 0 else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path)
    }
}
#endif
