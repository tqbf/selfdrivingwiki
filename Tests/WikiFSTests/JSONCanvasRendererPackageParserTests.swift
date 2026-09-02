import Foundation
import Testing

/// Normal-suite execution of the JSON Canvas package parser. It runs the exact
/// `__sdw_parse_canvas` entry that `viewer.js` exposes (the same function the
/// package renderer calls) inside a bounded, non-blocking `node` subprocess.
/// The test skips cleanly when `node` is not on PATH, so hosted WebKit remains
/// the authoritative renderer surface while this gives every `swift test`
/// deterministic at-cap/one-byte-over-cap parity for the pure parser.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct JSONCanvasRendererPackageParserTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("RendererPackages/JSONCanvas", isDirectory: true)

    @Test("node harness executes the package parser entry (smoke)")
    func nodeHarnessExecutesPackageParserEntry() async throws {
        try await runParserCase(label: "smoke", payload: Data(Self.validCanvas.utf8), expectOK: true)
    }

    @Test("parser accepts canvas at the declared cap and rejects one byte over")
    func acceptsAtPackageCapAndRejectsOneByteOverCap() async throws {
        // The package declares 48,000 bytes. Build a valid document padded with
        // whitespace up to exactly the cap, then one byte over.
        let base = try #require(Self.validCanvas.data(using: .utf8))
        let cap = 48_000
        let target = Data("{\"nodes\":[],\"edges\":[]}".utf8)
        let padding = cap - target.count
        let atCap = target + Data(repeating: 0x20, count: padding)
        let overCap = target + Data(repeating: 0x20, count: padding + 1)

        try await runParserCase(label: "at-cap", payload: atCap, expectOK: true)
        try await runParserCase(label: "over-cap", payload: overCap, expectOK: false)
        _ = base
    }

    @Test("parser rejects malformed, bounded, and unsafe documents")
    func rejectsMalformedBoundedAndUnsafeDocuments() async throws {
        let textNode = #"{"id":"note","type":"text","x":0,"y":0,"width":120,"height":60,"text":"Note"}"#
        let edge = #"{"id":"edge","fromNode":"note","toNode":"note2"}"#
        let malformed = Data("{\"nodes\":[]".utf8)
        let missingEdges = Data("{\"nodes\":[\(textNode)]}".utf8)
        let unknownEndpoint = Data("{\"nodes\":[\(textNode)],\"edges\":[\(edge)]}".utf8)
        let traversal = Data(#"""{"nodes":[{"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"../secret"}],"edges":[]}"""#.utf8)
        let scheme = Data(#"""{"nodes":[{"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"https:example"}],"edges":[]}"""#.utf8)
        let percent = Data(#"""{"nodes":[{"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"a%2Fb"}],"edges":[]}"""#.utf8)
        let oversizeText = Data(#"""{"nodes":[{"id":"note","type":"text","x":0,"y":0,"width":120,"height":60,"text":"""#.utf8)
            + Data("\"\(String(repeating: "x", count: 8_193))\"".utf8)
            + Data(#"""}],"edges":[]}"""#.utf8)

        try await runParserCase(label: "malformed", payload: malformed, expectOK: false)
        try await runParserCase(label: "missingEdges", payload: missingEdges, expectOK: false)
        try await runParserCase(label: "unknownEndpoint", payload: unknownEndpoint, expectOK: false)
        try await runParserCase(label: "traversal", payload: traversal, expectOK: false)
        try await runParserCase(label: "scheme", payload: scheme, expectOK: false)
        try await runParserCase(label: "percent", payload: percent, expectOK: false)
        try await runParserCase(label: "oversizeText", payload: oversizeText, expectOK: false)

        // Groups are supported: a bounded label and CSS color background.
        let groupValid = Data("{\"nodes\":[{\"id\":\"g\",\"type\":\"group\",\"x\":0,\"y\":0,\"width\":200,\"height\":100,\"label\":\"Group\",\"background\":\"#25c2a0\"}],\"edges\":[]}".utf8)
        let groupInvalidColor = Data("{\"nodes\":[{\"id\":\"g\",\"type\":\"group\",\"x\":0,\"y\":0,\"width\":200,\"height\":100,\"label\":\"Group\",\"background\":\"../secret\"}],\"edges\":[]}".utf8)
        try await runParserCase(label: "group-valid", payload: groupValid, expectOK: true)
        try await runParserCase(label: "group-invalid-color", payload: groupInvalidColor, expectOK: false)
    }

    // MARK: - Helpers

    private static var validCanvas: String {
        #"{"nodes":[{"id":"note","type":"text","x":20,"y":10,"width":160,"height":80,"text":"First note"},{"id":"note2","type":"text","x":220,"y":10,"width":160,"height":80,"text":"Second note"}],"edges":[{"id":"edge","fromNode":"note","toNode":"note2"}]}"#
    }

    /// Executes `viewer.js` with the global test entry and the given base64
    /// payload inside a bounded `node` subprocess, without blocking the
    /// cooperative thread pool. Skips quietly when `node` is unavailable.
    private func runParserCase(label: String, payload: Data, expectOK: Bool) async throws {
        guard Self.nodeAvailable else {
            Issue.record("node is not available on PATH; parser subprocess test skipped")
            return
        }
        let viewerURL = Self.packageRoot.appendingPathComponent("viewer.js")
        guard FileManager.default.fileExists(atPath: viewerURL.path) else {
            Issue.record("viewer.js is not present in the reviewed package; parser test skipped")
            return
        }
        let harness = """
        const viewer = require(process.env.JSONCANVAS_VIEWER);
        const result = viewer.parseCanvas(process.env.JSONCANVAS_PAYLOAD);
        process.stdout.write(result);
        """
        var environment = ProcessInfo.processInfo.environment
        environment["JSONCANVAS_VIEWER"] = viewerURL.path
        environment["JSONCANVAS_PAYLOAD"] = payload.base64EncodedString()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", harness]
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()

        try await asyncWaitUntilExit(process, timeout: .seconds(10))
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let ok = (parsed["ok"] as? Bool) ?? false
        if expectOK {
            #expect(ok == true, "expected parser success for \(label), got: \(text)")
        } else {
            #expect(ok == false, "expected parser rejection for \(label), got: \(text)")
        }
    }

    private static var nodeAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        // Avoid `waitUntilExit`; a short timeout still returns quickly.
        Thread.sleep(forTimeInterval: 0.5)
        return process.isRunning == false && process.terminationStatus == 0
    }

    /// Non-blocking `terminationHandler` + `CheckedContinuation` with a timeout
    /// safety net (never parks the cooperative thread pool).
    private func asyncWaitUntilExit(_ process: Process, timeout: Duration) async throws {
        let waiter = ProcessExitWaiter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        waiter.install(cont)
                        process.terminationHandler = { _ in _ = waiter.finish(.success(())) }
                        if !process.isRunning { _ = waiter.finish(.success(())) }
                    }
                } onCancel: {
                    if waiter.finish(.failure(CancellationError())), process.isRunning {
                        process.terminate()
                    }
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return }
                if process.isRunning { process.terminate() }
                _ = waiter.finish(.failure(ProcessExitWaitError.timedOut))
                throw ProcessExitWaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private enum ProcessExitWaitError: Error {
    case timedOut
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        let existing: CheckedContinuation<Void, Error>? = lock.withLock {
            let value = continuation
            continuation = nil
            return value
        }
        existing?.resume(with: result)
        return existing != nil
    }
}
