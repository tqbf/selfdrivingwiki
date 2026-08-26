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
case "success", "environment":
    let markdown: String
    if mode == "environment" {
        let environment = ProcessInfo.processInfo.environment
        let keys = [
            "HOME", "TMPDIR", "XDG_CACHE_HOME", "LANG", "LC_ALL",
            "WIKI_EXTRACTOR_REQUEST_ID", "WIKI_EXTRACTOR_PROTOCOL_REVISION",
            "WIKI_EXTRACTOR_SHARED_RUNTIME_CACHE", "WIKI_EXTRACTOR_SHARED_MODEL_CACHE",
            "PARENT_SECRET", "PATH",
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
default:
    exit(4)
}
