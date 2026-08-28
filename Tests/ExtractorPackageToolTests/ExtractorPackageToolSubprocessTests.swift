import ExtractorPackageToolCore
import Foundation
import Synchronization
import Testing
import WikiFSTypes

@Suite("Extractor package tool subprocess", .serialized, .timeLimit(.minutes(1)))
struct ExtractorPackageToolSubprocessTests {
    @Test func validateEmitsOneJSONObjectAndNoDiagnostic() async throws {
        let fixture = try SubprocessFixture()
        defer { fixture.cleanup() }
        let result = try await run(arguments: ["validate", fixture.packageRoot.path])

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        let output = try JSONDecoder().decode(
            ExtractorPackageValidationOutput.self,
            from: result.standardOutput)
        #expect(output.command == "validate")
        #expect(output.packageID == "org.example.subprocess")
        #expect(output.registrationIDs == ["pdf"])
        #expect(FileManager.default.fileExists(atPath: fixture.executionMarker.path) == false)
    }

    @Test func invalidArgumentsEmitStableDiagnosticAndFailureStatus() async throws {
        let result = try await run(arguments: [])

        #expect(result.status != 0)
        #expect(result.standardOutput.isEmpty)
        let diagnostic = try #require(String(data: result.standardError, encoding: .utf8))
        #expect(diagnostic.hasPrefix("extractor-package-tool: usage:"))
        #expect(diagnostic.contains("protocol-smoke"))
    }

    private func run(arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try executableURL()
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        let waiter = ProcessExitWaiter()
        process.terminationHandler = { process in
            waiter.finish(status: process.terminationStatus)
        }
        try process.run()
        let status = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await waiter.wait() }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw SubprocessError.timedOut
            }
            guard let value = try await group.next() else { throw SubprocessError.timedOut }
            group.cancelAll()
            return value
        }
        return ProcessResult(
            status: status,
            standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            standardError: standardError.fileHandleForReading.readDataToEndOfFile())
    }

    private func executableURL() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(
            at: repositoryRoot.appendingPathComponent(".build", isDirectory: true),
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == "extractor-package-tool",
                  FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        throw SubprocessError.executableNotFound
    }
}

private struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

private enum SubprocessError: Error {
    case executableNotFound
    case timedOut
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Int32, any Error>?
        var result: Result<Int32, any Error>?
    }

    private let state = Mutex(State())

    func wait() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = state.withLock { state -> Result<Int32, any Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            finish(result: .failure(CancellationError()))
        }
    }

    func finish(status: Int32) {
        finish(result: .success(status))
    }

    private func finish(result: Result<Int32, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Int32, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class SubprocessFixture: @unchecked Sendable {
    let root: URL
    let packageRoot: URL
    let executionMarker: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-package-subprocess-\(UUID().uuidString)", isDirectory: true)
        packageRoot = root.appendingPathComponent("package", isDirectory: true)
        executionMarker = root.appendingPathComponent("executed")
        let entry = packageRoot.appendingPathComponent("bin/extractor")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("#!/bin/sh\ntouch \"\(executionMarker.path)\"\n".utf8)
        try bytes.write(to: entry)
        guard chmod(entry.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        let entryPath = try ExtractorRelativePath(validating: "bin/extractor")
        let manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.subprocess"),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Subprocess Fixture",
            protocolRevision: .v1,
            entryPoint: entryPath,
            launch: .direct,
            registrations: [ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(path: entryPath, digest: ExtractorSHA256.digest(bytes))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 4))
        try JSONEncoder().encode(manifest).write(to: packageRoot.appendingPathComponent("manifest.json"))
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Extractor package subprocess fixture cleanup failed: \(error)") }
    }
}
