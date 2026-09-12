import Darwin
import Foundation

private struct Request: Decodable {
    let requestID: UUID
    let inputPath: String
    let outputPath: String
}

private struct Frame<Payload: Encodable>: Encodable {
    let kind: String
    let payload: Payload
}

private struct Progress: Encodable {
    let requestID: UUID
    let completedUnitCount: Int?
    let totalUnitCount: Int?
    let message: String?
}

private struct ArticleMetadata: Encodable {
    let title: String?
    let author: String?
    let wordCount: Int?
}

private struct Result: Encodable {
    let requestID: UUID
    let outputPath: String
    let markdownByteCount: Int
    var articleMetadata: ArticleMetadata?
}

private struct Failure: Encodable {
    let requestID: UUID
    let cause: String
    let message: String
}

private func write<T: Encodable>(_ frame: Frame<T>) throws {
    var data = try JSONEncoder().encode(frame)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func spawnChild() throws -> pid_t {
    let executable = "/bin/sleep"
    let values = ["sleep", "3600"]
    let allocated = values.map { strdup($0) }
    defer { allocated.forEach { free($0) } }
    var arguments = allocated + [nil]
    var childPID: pid_t = 0
    let result = executable.withCString {
        posix_spawn(&childPID, $0, nil, nil, &arguments, environ)
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    return childPID
}

/// Shared tail of the sandbox-enforcement modes: write the report markdown
/// INSIDE the operation root (which the profile allows) and emit a valid
/// progress + result terminal exchange, so the host sees a successful
/// operation whose markdown carries the verdict.
private func emitCompletion(
    requestID: UUID,
    outputPath: String,
    markdown: String
) -> Bool {
    do {
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(markdown.utf8).write(to: outputURL)
        try write(Frame(
            kind: "progress",
            payload: Progress(
                requestID: requestID,
                completedUnitCount: 1,
                totalUnitCount: 1,
                message: "complete")))
        try write(Frame(
            kind: "result",
            payload: Result(
                requestID: requestID,
                outputPath: outputPath,
                markdownByteCount: markdown.utf8.count)))
        return true
    } catch {
        return false
    }
}

/// Direct BSD-socket connect probe with a bounded 3 s timeout — no `nc`/`curl`,
/// because the child environment is a deliberately closed allowlist. Returns a
/// verdict string for the NETWORK report: `ok` when the connection was
/// established, `denied` when the seatbelt refused it (EPERM/EACCES), and a
/// distinct `error-<errno>` otherwise so an environment without enforcement
/// fails loudly instead of silently matching.
private func probeTCP(host: String, port: Int) -> String {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(clamping: port).bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return "error-host" }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return "error-socket-\(errno)" }
    defer { close(descriptor) }
    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        return "error-fcntl-\(errno)"
    }
    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connectResult == 0 { return "ok" }
    if errno == EPERM || errno == EACCES { return "denied" }
    guard errno == EINPROGRESS else { return "error-connect-\(errno)" }
    var pollSet = [pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)]
    guard poll(&pollSet, 1, 3_000) > 0 else { return "error-timeout" }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
        return "error-getsockopt-\(errno)"
    }
    if socketError == 0 { return "ok" }
    if socketError == EPERM || socketError == EACCES { return "denied" }
    return "error-\(socketError)"
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let requestData = input.last == 0x0A ? input.dropLast() : input[...]
private let request: Request
do {
    request = try JSONDecoder().decode(Request.self, from: Data(requestData))
} catch {
    exit(2)
}
let sourceURL = URL(fileURLWithPath: request.inputPath)
let mode: String
do {
    mode = try String(contentsOf: sourceURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
} catch {
    exit(5)
}

switch mode {
case "success", "environment", "linger":
    let markdown: String
    if mode == "environment" {
        let environment = ProcessInfo.processInfo.environment
        let keys = [
            "HOME", "TMPDIR", "XDG_CACHE_HOME", "LANG", "LC_ALL",
            "WIKI_EXTRACTOR_REQUEST_ID", "WIKI_EXTRACTOR_PROTOCOL_REVISION",
            "WIKI_EXTRACTOR_SHARED_RUNTIME_CACHE", "WIKI_EXTRACTOR_SHARED_MODEL_CACHE",
            "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR",
            "PARENT_SECRET", "PATH", "MISE_DATA_DIR", "MISE_CONFIG_DIR",
        ]
        markdown = keys.map { "\($0)=\(environment[$0] ?? "<missing>")" }.joined(separator: "\n")
    } else {
        markdown = "# Fixture\n"
    }
    do {
        let outputURL = URL(fileURLWithPath: request.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(markdown.utf8).write(to: outputURL)
        try write(Frame(
            kind: "progress",
            payload: Progress(
                requestID: request.requestID,
                completedUnitCount: 1,
                totalUnitCount: 1,
                message: "complete")))
        try write(Frame(
            kind: "result",
            payload: Result(
                requestID: request.requestID,
                outputPath: request.outputPath,
                markdownByteCount: markdown.utf8.count)))
    } catch {
        exit(3)
    }
    // Mode "linger": the protocol exchange is complete, but the wrapper
    // process outlives the package — the observed `uv run` hang. The host
    // must treat the terminal frame as completion and reap the group.
    if mode == "linger" {
        while true { _ = Darwin.pause() }
    }
case "failure":
    do {
        try write(Frame(
            kind: "failure",
            payload: Failure(
                requestID: request.requestID,
                cause: "extraction-failure",
                message: "fixture failure")))
    } catch {
        exit(3)
    }
case "malformed", "malformed-hold":
    do {
        try FileHandle.standardOutput.write(contentsOf: Data("not-json\n".utf8))
    } catch {
        exit(3)
    }
    if mode == "malformed-hold" {
        while true { _ = Darwin.pause() }
    }
case "nonzero":
    do {
        try FileHandle.standardError.write(contentsOf: Data("fixture failed\n".utf8))
    } catch {
        exit(3)
    }
    exit(17)
case "hold":
    do {
        let childPID = try spawnChild()
        try Data(String(childPID).utf8).write(
            to: URL(fileURLWithPath: request.outputPath))
    } catch {
        exit(3)
    }
    while true { _ = Darwin.pause() }
case "htmlsuccess":
    let markdown = "# Hello\n\nWorld.\n"
    do {
        let outputURL = URL(fileURLWithPath: request.outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(markdown.utf8).write(to: outputURL)
        try write(Frame(
            kind: "progress",
            payload: Progress(
                requestID: request.requestID,
                completedUnitCount: 1,
                totalUnitCount: 1,
                message: "complete")))
        try write(Frame(
            kind: "result",
            payload: Result(
                requestID: request.requestID,
                outputPath: request.outputPath,
                markdownByteCount: markdown.utf8.count,
                articleMetadata: ArticleMetadata(
                    title: "Hello",
                    author: "Jane Doe",
                    wordCount: 2))))
    } catch {
        exit(3)
    }
case let modeLine where modeLine.hasPrefix("outside-write"):
    // "outside-write <absolute path OUTSIDE the operation root>". The write
    // attempt must be denied by the seatbelt; the report markdown still lands
    // inside the operation root and carries the verdict.
    let target = String(modeLine.dropFirst("outside-write".count))
        .trimmingCharacters(in: .whitespaces)
    let outcome: String
    do {
        try Data("outside".utf8).write(to: URL(fileURLWithPath: target))
        outcome = "ok"
    } catch {
        outcome = "denied"
    }
    guard emitCompletion(
        requestID: request.requestID,
        outputPath: request.outputPath,
        markdown: "# Fixture\nOUTSIDE=\(outcome)\n")
    else {
        exit(3)
    }
case let modeLine where modeLine.hasPrefix("tcp-connect"):
    // "tcp-connect <host> <port>". Reports whether a TCP connection was
    // established; under the seatbelt it must be denied unless the manifest
    // declared the network capability.
    let parts = modeLine.dropFirst("tcp-connect".count)
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
    guard parts.count == 2, let port = Int(parts[1]) else {
        exit(4)
    }
    let outcome = probeTCP(host: parts[0], port: port)
    guard emitCompletion(
        requestID: request.requestID,
        outputPath: request.outputPath,
        markdown: "# Fixture\nNETWORK=\(outcome)\n")
    else {
        exit(3)
    }
default:
    exit(4)
}
