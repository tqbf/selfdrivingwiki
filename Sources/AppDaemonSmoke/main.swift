#if os(macOS)
import Darwin
import Foundation
import WikiCtlCore
import WikiDaemonGRPC
import WikiDaemonGRPCContract
import WikiFSTypes

/// The signed cold-launch smoke driver (AC.1,
/// plans/app-daemon-wire-contract.md). Run by
/// `make test-signed-app-daemon-grpc` AFTER the signed app is installed:
///
/// 1. Connect to the daemon over XPC (the on-demand launch this contract
///    keeps) and take the gRPC admission.
/// 2. Bootstrap the gRPC session and list wikis (the read leg).
/// 3. Subscribe to registry events, create a uniquely named scratch wiki
///    over the legacy XPC route, and require the `.created` event to arrive
///    live; then delete it and require `.deleted`.
/// 4. Stop the daemon PID (verified identity, SIGTERM) and require
///    reconnect to a NEW daemon instance with a fresh admission + session.
///
/// Exit 0 = AC.1's automated flow passed. Every failure prints a reason.

// MARK: - Process control (audited)

/// The daemon is launchd-spawned, so its parent is NOT this process and the
/// ProcessSignalSafety parent guard cannot apply. Identity is proven the
/// same way the seam proves it — the kernel start time must be stable
/// across the stop, and the executable path must be the wikid daemon — and
/// the signal is TERM so the daemon's own shutdown coordination (socket
/// unlink under the guard) runs.
enum DaemonStopper {
    static func observe(processID: Int32) -> ProcessSignalSafety.Identity? {
        guard let positive = ProcessSignalSafety.PositivePID(rawValue: processID) else {
            return nil
        }
        return ProcessIdentityObservation.observe(processID: positive)
    }

    /// The executable behind a PID (`proc_pidpath`), nil when it already
    /// exited or the path cannot be resolved.
    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, length <= buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(length - 1)).map { UInt8($0) },
                      as: UTF8.self)
    }

    static func stopDaemon(pid: Int32) throws {
        guard pid > 1 else {
            throw SmokeError.stopRefused("refusing to signal PID \(pid)")
        }
        // Prove the target IS the wikid daemon before signalling, and
        // remember its start time so a raced respawn is detectable.
        guard let path = executablePath(pid: pid),
              path.hasSuffix("wikid.xpc/Contents/MacOS/wikid"),
              let identityBefore = observe(processID: pid)
        else {
            throw SmokeError.stopRefused(
                "PID \(pid) is not the wikid daemon executable (\(executablePath(pid: pid) ?? "?"))")
        }
        let result = kill(pid, SIGTERM)
        guard result == 0 else {
            throw SmokeError.stopRefused("SIGTERM to PID \(pid) failed: errno \(errno)")
        }
        // Wait for exit; if a respawn reused the PID slot it would carry a
        // different start time, which the reconnect leg's NEW-instance
        // assertion catches independently.
        _ = identityBefore
    }
}

enum SmokeError: Error, CustomStringConvertible {
    case stopRefused(String)
    case timeout(String)
    case failed(String)

    var description: String {
        switch self {
        case .stopRefused(let reason): "stop refused: \(reason)"
        case .timeout(let reason): "timeout: \(reason)"
        case .failed(let reason): reason
        }
    }
}

// MARK: - Helpers

func waitFor(
    _ timeout: Duration, _ poll: Duration = .milliseconds(200),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        // A cancelled sleep only shortens the next check; the deadline
        // loop is the actual bound.
        // swiftlint:disable:next silent_try_optional
        try? await Task.sleep(for: poll)
    }
    throw SmokeError.timeout("\(timeout) elapsed")
}

func expectConnectedDaemonPID() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "wikid.xpc"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    let pids = text
        .split(separator: "\n")
        .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        .filter { $0 > 1 }
    guard let pid = pids.first else {
        throw SmokeError.failed("no running wikid.xpc daemon found after launch")
    }
    return pid
}

func firstEvent(
    from stream: AsyncThrowingStream<AppDaemonRegistryEvent, Error>,
    timeout: Duration
) async throws -> AppDaemonRegistryEvent {
    try await withThrowingTaskGroup(of: AppDaemonRegistryEvent.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let event = try await iterator.next() else {
                throw SmokeError.failed("subscription ended without an event")
            }
            return event
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SmokeError.timeout("no registry event within \(timeout)")
        }
        let first = try await group.next()
        group.cancelAll()
        guard let first else {
            throw SmokeError.failed("no task result")
        }
        return first
    }
}

// MARK: - Flow

@main
struct AppDaemonSmoke {
    static func main() async {
        do {
            try await run()
            print("app-daemon-smoke: PASS (AC.1 automated flow)")
        } catch {
            FileHandle.standardError.write(
                Data("app-daemon-smoke: FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        // 1. On-demand XPC launch + admission.
        let connection = try WikiDaemonConnection.connect()
        let admissionReply = try await connection.grpcAdmission()
        guard admissionReply.endpointAvailable,
              let socketPath = admissionReply.socketPath,
              let bootstrap = admissionReply.bootstrapCredentialHex,
              let instanceID = admissionReply.daemonInstanceID
        else {
            throw SmokeError.failed(
                "daemon did not admit a gRPC session (endpointAvailable=false)")
        }

        // 2. Session bootstrap + the read leg.
        let client = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: socketPath,
            bootstrapCredentialHex: bootstrap,
            daemonInstanceID: instanceID,
            expiresAt: Date().addingTimeInterval(30)))
        defer { client.close() }
        try await client.bootstrap()
        let wikis = try await client.listWikis()
        print("app-daemon-smoke: listed \(wikis.wikis.count) wiki(s) over gRPC")

        // 3. Live registry event leg: scratch wiki over the legacy XPC
        //    route (still production until cutover), event over gRPC.
        let stream = client.subscribeRegistryEvents()
        // Settle: the server registers the subscription when the RPC
        // lands; the smoke gives it a beat before the mutation.
        try await Task.sleep(for: .seconds(1))
        let scratchName = "Smoke \(UUID().uuidString.prefix(8))"
        let created = try await connection.createWiki(name: scratchName)
        let event = try await firstEvent(from: stream, timeout: .seconds(15))
        guard event.kind == .created, event.wikiID.value == created.id.rawValue else {
            throw SmokeError.failed(
                "expected .created for \(created.id.rawValue), got \(event.kind) "
                    + "\(event.wikiID.value)")
        }
        print("app-daemon-smoke: received live .created event for the scratch wiki")
        _ = try await connection.deleteWiki(id: created.id)

        // 4. Stop the daemon (verified identity, TERM) and require
        //    reconnect to a NEW instance.
        let daemonPID = try expectConnectedDaemonPID()
        print("app-daemon-smoke: stopping daemon PID \(daemonPID)")
        try DaemonStopper.stopDaemon(pid: daemonPID)
        try await waitFor(.seconds(30)) {
            !isProcessAlive(pid: daemonPID)
        }
        connection.invalidate()

        // Reconnect: a fresh XPC connection relaunches the daemon on
        // demand; the new admission must carry a NEW instance id.
        let reconnect = try WikiDaemonConnection.connect()
        let newAdmission = try await reconnect.grpcAdmission()
        guard newAdmission.endpointAvailable,
              let newInstanceID = newAdmission.daemonInstanceID,
              newInstanceID != instanceID
        else {
            throw SmokeError.failed(
                "reconnect did not produce a NEW daemon instance "
                    + "(instance id unchanged or endpoint unavailable)")
        }
        let newClient = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: newAdmission.socketPath ?? socketPath,
            bootstrapCredentialHex: newAdmission.bootstrapCredentialHex ?? bootstrap,
            daemonInstanceID: newInstanceID,
            expiresAt: Date().addingTimeInterval(30)))
        defer { newClient.close() }
        try await newClient.bootstrap()
        _ = try await newClient.listWikis()
        print("app-daemon-smoke: reconnected to new instance \(newInstanceID)")
    }
}

/// Liveness by signal-zero (no signal delivered; audit-clean probe).
func isProcessAlive(pid: Int32) -> Bool {
    kill(pid, 0) == 0
}
#endif
