import Darwin
import Foundation

private enum FixtureMode: String, Codable {
    case success
    case holdWithChild
    // Test-only: spawns `childPath` with `childArguments` and a private stdin
    // pipe seeded with `childStandardInput`, reports the child PID, then
    // exits immediately — deliberately orphaning the child so tests can
    // verify the child's own failsafes (#1259).
    case spawnChildAndExit
}

private struct FixtureRequest: Codable {
    let version: Int
    let requestID: String
    let mode: FixtureMode
    var childPath: String?
    var childArguments: [String]?
    var childStandardInput: Data?
    // spawnChildAndExit: how long to stay alive after reporting the child
    // PID, so the child's main can start while its true parent still exists
    // (letting tests exercise the parent-death TRANSITION, not just
    // orphan-at-birth). Clamped to 0...10_000 ms.
    var preExitDelayMilliseconds: Int?
}

private struct FixtureFrame: Encodable {
    let version: Int
    let requestID: String
    let kind: String
    let message: String?
    let childPID: Int32?
    let success: Bool?

    static func progress(requestID: String, message: String, childPID: Int32? = nil) -> Self {
        Self(version: 1, requestID: requestID, kind: "progress", message: message,
             childPID: childPID, success: nil)
    }

    static func result(requestID: String) -> Self {
        Self(version: 1, requestID: requestID, kind: "result", message: nil,
             childPID: nil, success: true)
    }
}

private func writeFrame(_ frame: FixtureFrame) throws {
    var data = try JSONEncoder().encode(frame)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func diagnostic(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    do {
        try FileHandle.standardError.write(contentsOf: data)
    } catch {
        // Diagnostics are best effort and must never affect the fixture protocol.
    }
}

private func spawnGroupChild() throws -> pid_t {
    let executable = "/bin/sleep"
    let arguments = ["sleep", "3600"]
    return try posixSpawn(executable, arguments, stdinFD: nil)
}

/// Spawn `executable` with the given arguments. When `stdinFD` is set, the
/// child's stdin is dup2'd from that read-end descriptor; `writeFDToClose`
/// (the matching write end the child also inherited from the pre-spawn
/// pipe()) is closed in the child so the child observes EOF when the parent
/// finishes writing. stdout/stderr are always inherited, so the child shares
/// this fixture's pipes with the supervising runner.
private func posixSpawn(
    _ executable: String,
    _ arguments: [String],
    stdinFD: Int32?,
    writeFDToClose: Int32? = nil
) throws -> pid_t {
    let mutableArguments = arguments.map { strdup($0) }
    defer { mutableArguments.forEach { free($0) } }
    var argv = mutableArguments + [nil]
    var childPID: pid_t = 0

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let stdinFD {
        posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdinFD)
    }
    if let writeFDToClose {
        posix_spawn_file_actions_addclose(&actions, writeFDToClose)
    }
    let result = executable.withCString { path in
        posix_spawn(&childPID, path, &actions, nil, &argv, environ)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
    }
    return childPID
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let lines = String(decoding: input, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
let requestLine: Substring
if lines.count == 1 {
    requestLine = lines[0]
} else if lines.count == 2, lines[1].isEmpty {
    requestLine = lines[0]
} else {
    diagnostic("expected exactly one UTF-8 JSON line followed by EOF")
    exit(EXIT_FAILURE)
}

guard let requestData = requestLine.data(using: .utf8) else {
    diagnostic("fixture request is not UTF-8")
    exit(EXIT_FAILURE)
}
private let request: FixtureRequest
do {
    request = try JSONDecoder().decode(FixtureRequest.self, from: requestData)
} catch {
    diagnostic("fixture request is not valid JSON")
    exit(EXIT_FAILURE)
}
guard request.version == 1, !request.requestID.isEmpty else {
    diagnostic("invalid fixture request")
    exit(EXIT_FAILURE)
}

do {
    switch request.mode {
    case .success:
        try writeFrame(.progress(requestID: request.requestID, message: "started"))
        try writeFrame(.result(requestID: request.requestID))
    case .holdWithChild:
        let childPID = try spawnGroupChild()
        try writeFrame(.progress(requestID: request.requestID, message: "child started", childPID: childPID))
        // Self-termination ceiling: the hold exists to be killed by the
        // supervising runner's verified group signal. If every supervisor
        // disappears, alarm(2) ends the hold (and its sleep child outlives
        // it by at most its own 1h ceiling) instead of lingering forever.
        alarm(600)
        while true {
            _ = Darwin.pause()
        }
    case .spawnChildAndExit:
        guard let childPath = request.childPath else {
            diagnostic("spawnChildAndExit requires childPath")
            exit(EXIT_FAILURE)
        }
        // Private stdin pipe for the child, seeded with the requested bytes:
        // the child must be busy on real work (not starved into an instant
        // EOF exit) when this fixture orphans it.
        var stdinFDs: [Int32] = [-1, -1]
        guard pipe(&stdinFDs) == 0 else {
            diagnostic("child stdin pipe failed")
            exit(EXIT_FAILURE)
        }
        let childPID = try posixSpawn(
            childPath,
            request.childArguments ?? [],
            stdinFD: stdinFDs[0],
            writeFDToClose: stdinFDs[1])
        close(stdinFDs[0])
        if let seed = request.childStandardInput {
            seed.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    guard let base = raw.baseAddress else { return }
                    let n = write(stdinFDs[1], base + offset, raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
        close(stdinFDs[1])
        try writeFrame(.progress(requestID: request.requestID, message: "child spawned", childPID: childPID))
        // Optional linger before orphaning, clamped to 10 s.
        if let delay = request.preExitDelayMilliseconds {
            usleep(useconds_t(max(0, min(delay, 10_000)) * 1_000))
        }
        // Exit WITHOUT waiting: orphaning the child is the point. The
        // child's own failsafes (self-deadline, orphan poll) are what must
        // terminate it.
        exit(EXIT_SUCCESS)
    }
} catch {
    diagnostic("fixture failed: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
