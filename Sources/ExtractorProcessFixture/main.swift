import Darwin
import Foundation

private enum FixtureMode: String, Codable {
    case success
    case holdWithChild
}

private struct FixtureRequest: Codable {
    let version: Int
    let requestID: String
    let mode: FixtureMode
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
    let mutableArguments = arguments.map { strdup($0) }
    defer { mutableArguments.forEach { free($0) } }
    var argv = mutableArguments + [nil]
    var childPID: pid_t = 0
    let result = executable.withCString { path in
        posix_spawn(&childPID, path, nil, nil, &argv, environ)
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
        while true {
            _ = Darwin.pause()
        }
    }
} catch {
    diagnostic("fixture failed: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
