import Foundation
import RendererPackageToolCore
import Testing

@Suite("Renderer package tool subprocess", .serialized, .timeLimit(.minutes(1)))
struct RendererPackageToolSubprocessTests {
    @Test("validate command emits JSON on stdout and exits zero")
    func validateCommandEmitsJSONAndExitsZero() async throws {
        let result = try await run(arguments: ["validate", Self.templateRoot.path])
        let output = try JSONDecoder().decode(RendererPackageValidationOutput.self, from: result.stdout)

        #expect(result.status == 0)
        #expect(output.packageID == "org.example.readonly")
        #expect(output.version == "1.0.0")
        #expect(output.registrationIDs == ["example"])
        #expect(!output.packageHash.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("invalid package emits only an actionable stderr diagnostic and exits nonzero")
    func invalidPackageEmitsDiagnosticAndExitsNonzero() async throws {
        let missing = Self.repositoryRoot.appending(path: "missing-renderer-package")
        let result = try await run(arguments: ["validate", missing.path])
        let diagnostic = try #require(String(data: result.stderr, encoding: .utf8))

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
        #expect(diagnostic.contains("RendererPackageTool: validation failed: the package path does not exist"))
    }

    @Test("validate command accepts the reviewed mermaid package and reports its registration")
    func validateCommandAcceptsReviewedMermaidPackage() async throws {
        let result = try await run(arguments: ["validate", Self.mermaidPackageRoot.path])
        let output = try JSONDecoder().decode(RendererPackageValidationOutput.self, from: result.stdout)

        #expect(result.status == 0)
        #expect(output.packageID == "org.selfdrivingwiki.mermaid-readonly")
        #expect(output.version == "1.0.0")
        #expect(output.registrationIDs == ["mermaid"])
        #expect(!output.packageHash.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    private func run(arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments
        let captureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-package-tool-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: captureRoot) }
            catch { Issue.record("Renderer package process capture cleanup failed: \(error)") }
        }
        let stdoutURL = captureRoot.appending(path: "stdout")
        let stderrURL = captureRoot.appending(path: "stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw ProcessFailure.captureCreationFailed
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            do { try stdout.close() }
            catch { Issue.record("Renderer package stdout capture close failed: \(error)") }
            do { try stderr.close() }
            catch { Issue.record("Renderer package stderr capture close failed: \(error)") }
        }
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        try await waitForExit(process, timeout: .seconds(30))
        try stdout.synchronize()
        try stderr.synchronize()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL))
    }

    private func executableURL() throws -> URL {
        let buildRoot = Self.repositoryRoot.appending(path: ".build")
        let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == "RendererPackageTool",
                  candidate.path.contains(".build/") && !candidate.path.contains(".dSYM/"),
                  FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        throw ProcessFailure.executableNotFound
    }

    private func waitForExit(_ process: Process, timeout: Duration) async throws {
        let waiter = ProcessExitWaiter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        waiter.install(continuation)
                        process.terminationHandler = { _ in waiter.finish(.success(())) }
                        if !process.isRunning { waiter.finish(.success(())) }
                    }
                } onCancel: {
                    if waiter.finish(.failure(CancellationError())), process.isRunning {
                        process.terminate()
                    }
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                guard waiter.finish(.failure(ProcessFailure.timedOut)) else { return }
                if process.isRunning {
                    process.terminate()
                    let clock = ContinuousClock()
                    let terminationDeadline = clock.now.advanced(by: .seconds(5))
                    while process.isRunning && clock.now < terminationDeadline {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                throw ProcessFailure.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let templateRoot = repositoryRoot
        .appending(path: "docs/skills/renderer-package-maintainer/assets/minimal-renderer-package")
    private static let mermaidPackageRoot = repositoryRoot
        .appending(path: "RendererPackages/Mermaid")
}

private struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private enum ProcessFailure: Error {
    case captureCreationFailed
    case executableNotFound
    case timedOut
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let storedResult = lock.withLock { () -> Result<Void, any Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let storedResult { continuation.resume(with: storedResult) }
    }

    @discardableResult
    func finish(_ result: Result<Void, any Error>) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }
}
