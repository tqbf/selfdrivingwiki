#if os(macOS)
import Foundation

/// Socket-path contract for the app↔daemon gRPC endpoint.
///
/// The endpoint lives at `g/s` inside a mode-0700 `g/` directory under the App
/// Group container. Short names keep the complete UTF-8 path well inside the
/// `sockaddr_un` limit even when a developer's container path is long; a path
/// that does NOT fit is a typed failure before bind — never truncation, never
/// a fallback outside the container (plans/app-daemon-wire-contract.md,
/// "Transport and admission rules").
public enum DaemonGRPCSocketPaths {

    /// The `sockaddr_un.sun_path` byte budget on Darwin: 104 bytes INCLUDING
    /// the NUL terminator. A path of exactly 104 UTF-8 bytes does not fit.
    public static let maxPathBytes = 103

    /// The guard-flock file, inside the same private directory as the socket.
    /// Held for the listener's process lifetime: a second live listener fails
    /// at init (typed ownership failure) and can never unlink a served socket.
    public static let guardFileName = "grpc.lock"

    /// The private directory holding the socket, created mode 0700 and
    /// tightened when looser.
    public static let directoryName = "g"

    /// The socket file name.
    public static let socketFileName = "s"

    /// The complete private directory URL under an App Group container.
    public static func directory(inContainer container: URL) -> URL {
        container.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The complete socket path under an App Group container.
    /// - Throws: ``DaemonGRPCSocketError/pathTooLong(limit:actual:)`` when the
    ///   composed path exceeds ``maxPathBytes``.
    public static func socketPath(inContainer container: URL) throws -> String {
        let path = directory(inContainer: container)
            .appendingPathComponent(socketFileName, isDirectory: false).path
        let byteCount = path.utf8.count
        guard byteCount <= maxPathBytes else {
            throw DaemonGRPCSocketError.pathTooLong(limit: maxPathBytes, actual: byteCount)
        }
        return path
    }

    /// The complete guard-flock path under an App Group container.
    public static func guardPath(inContainer container: URL) -> String {
        directory(inContainer: container)
            .appendingPathComponent(guardFileName, isDirectory: false).path
    }
}

/// Typed failures of the gRPC endpoint's path and ownership contract.
public enum DaemonGRPCSocketError: Error, Equatable, Sendable {
    /// The composed socket path exceeds the `sockaddr_un` limit. Operator
    /// action: shorten the container path (per-developer App Group id); the
    /// daemon never truncates and never binds outside the container.
    case pathTooLong(limit: Int, actual: Int)

    /// Another live listener owns this endpoint (the guard flock is held).
    /// Contains the endpoint that is already served. Service continues from
    /// the existing listener; this process does not touch its socket.
    case serverAlreadyRunning(path: String)

    /// A POSIX failure with the operation it came from.
    case posix(operation: String, errno: Int32)

    /// start() was called twice on one listener instance.
    case serverAlreadyStarted

    /// stop() is terminal; the instance cannot restart.
    case serverStopped
}
#endif
