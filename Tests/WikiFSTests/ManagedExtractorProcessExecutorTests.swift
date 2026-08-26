import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

@Suite("Managed extractor process executor", .serialized, .timeLimit(.minutes(2)))
struct ManagedExtractorProcessExecutorTests {
    @Test func directExecutionStreamsProgressAndReturnsTerminalResult() async throws {
        let fixture = try Fixture(mode: "success")
        defer { fixture.cleanup() }
        let frames = FrameCollector()

        let result = try await ManagedExtractorProcessExecutor().execute(
            fixture.operation,
            onFrame: { frames.append($0) })

        #expect(result.terminationCause == .exited(code: 0))
        #expect(result.progressEventCount == 1)
        #expect(frames.values.count == 2)
        #expect(result.terminalFrame.isTerminal)
        #expect(try String(contentsOf: fixture.outputURL, encoding: .utf8) == "# Fixture\n")
    }

    @Test func environmentIsAllowlistedAndCapabilityGated() async throws {
        setenv("PARENT_SECRET", "must-not-leak", 1)
        defer { unsetenv("PARENT_SECRET") }
        let fixture = try Fixture(mode: "environment")
        defer { fixture.cleanup() }

        _ = try await ManagedExtractorProcessExecutor().execute(fixture.operation)
        let environment = try String(contentsOf: fixture.outputURL, encoding: .utf8)

        #expect(environment.contains("HOME=\(fixture.homeRoot.path)"))
        #expect(environment.contains("TMPDIR=\(fixture.temporaryRoot.path)"))
        #expect(environment.contains("PARENT_SECRET=<missing>"))
        #expect(environment.contains("PATH=<missing>"))
        #expect(environment.contains("WIKI_EXTRACTOR_SHARED_RUNTIME_CACHE=<missing>"))
        #expect(environment.contains("WIKI_EXTRACTOR_SHARED_MODEL_CACHE=<missing>"))
    }

    @Test func runtimeResolutionIsAbsoluteAndMissingRuntimeIsTyped() async throws {
        let fixture = try Fixture(mode: "success", launch: .runtime(
            command: ExtractorRuntimeName(validating: "missing-runtime"),
            arguments: []))
        defer { fixture.cleanup() }

        await #expect(throws: ManagedExtractorProcessError.missingRuntime(
            try ExtractorRuntimeName(validating: "missing-runtime"))) {
            _ = try await ManagedExtractorProcessExecutor().execute(fixture.operation)
        }
    }

    @Test func malformedProtocolAndNonzeroExitAreTyped() async throws {
        let malformed = try Fixture(mode: "malformed")
        defer { malformed.cleanup() }
        await #expect(throws: ManagedExtractorProcessError.malformedProtocol) {
            _ = try await ManagedExtractorProcessExecutor().execute(malformed.operation)
        }

        let nonzero = try Fixture(mode: "nonzero")
        defer { nonzero.cleanup() }
        await #expect(throws: ManagedExtractorProcessError.processTermination(.exited(code: 17))) {
            _ = try await ManagedExtractorProcessExecutor().execute(nonzero.operation)
        }
    }

    @Test func malformedProtocolTerminatesHoldingProcessPromptly() async throws {
        let fixture = try Fixture(mode: "malformed-hold", maximumDurationMilliseconds: 10_000)
        defer { fixture.cleanup() }
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: ManagedExtractorProcessError.malformedProtocol) {
            _ = try await ManagedExtractorProcessExecutor().execute(fixture.operation)
        }
        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test func timeoutTerminatesAndReapsProcessGroup() async throws {
        let fixture = try Fixture(mode: "hold", maximumDurationMilliseconds: 50)
        defer { fixture.cleanup() }

        await #expect(throws: ManagedExtractorProcessError.timeout) {
            _ = try await ManagedExtractorProcessExecutor().execute(fixture.operation)
        }
        let childPID = try Int32(String(contentsOf: fixture.outputURL, encoding: .utf8))
        #expect(await processIsGone(childPID))
    }

    @Test func cancellationTerminatesAndReapsProcessGroup() async throws {
        let fixture = try Fixture(mode: "hold", maximumDurationMilliseconds: 10_000)
        defer { fixture.cleanup() }
        let task = Task {
            try await ManagedExtractorProcessExecutor().execute(fixture.operation)
        }
        try await waitForFile(fixture.outputURL)
        task.cancel()

        await #expect(throws: ManagedExtractorProcessError.cancellation) {
            _ = try await task.value
        }
        let childPID = try Int32(String(contentsOf: fixture.outputURL, encoding: .utf8))
        #expect(await processIsGone(childPID))
    }

    private func waitForFile(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while FileManager.default.fileExists(atPath: url.path) == false {
            guard clock.now < deadline else { throw TestFailure("fixture output timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func processIsGone(_ rawPID: Int32?) async -> Bool {
        guard let rawPID,
              let pid = ProcessSignalSafety.PositivePID(rawValue: rawPID) else { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if ProcessIdentityObservation.observe(processID: pid) == nil { return true }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        return ProcessIdentityObservation.observe(processID: pid) == nil
    }
}

private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExtractorProtocolFrame] = []

    func append(_ frame: ExtractorProtocolFrame) {
        lock.withLock { storage.append(frame) }
    }

    var values: [ExtractorProtocolFrame] { lock.withLock { storage } }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let operationRoot: URL
    let packageRoot: URL
    let homeRoot: URL
    let temporaryRoot: URL
    let cacheRoot: URL
    let inputURL: URL
    let outputURL: URL
    let operation: ManagedExtractorProcessRequest

    init(
        mode: String,
        launch: ExtractorLaunch = .direct,
        maximumDurationMilliseconds: Int = 5_000
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-extractor-\(UUID().uuidString)", isDirectory: true)
        operationRoot = root.appendingPathComponent("operation", isDirectory: true)
        packageRoot = operationRoot.appendingPathComponent("package", isDirectory: true)
        homeRoot = operationRoot.appendingPathComponent("home", isDirectory: true)
        temporaryRoot = operationRoot.appendingPathComponent("tmp", isDirectory: true)
        cacheRoot = operationRoot.appendingPathComponent("cache", isDirectory: true)
        inputURL = operationRoot.appendingPathComponent("input/source.bin")
        outputURL = operationRoot.appendingPathComponent("output/result.md")
        for directory in [
            packageRoot,
            homeRoot,
            temporaryRoot,
            cacheRoot,
            inputURL.deletingLastPathComponent(),
            outputURL.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try Data(mode.utf8).write(to: inputURL)
        let fixtureExecutable = try Self.fixtureExecutable()
        let entryPath = try ExtractorRelativePath(validating: "bin/fixture")
        let entryURL = packageRoot.appendingPathComponent(entryPath.rawValue)
        try FileManager.default.createDirectory(
            at: entryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: fixtureExecutable)
        try bytes.write(to: entryURL)
        guard chmod(entryURL.path, 0o500) == 0 else { throw POSIXError(.EIO) }
        let manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.managed-fixture"),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Managed Fixture",
            protocolRevision: .v1,
            entryPoint: entryPath,
            launch: launch,
            registrations: [ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(path: entryPath, digest: ExtractorSHA256.digest(bytes))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 16 * 1_024,
                maximumDurationMilliseconds: maximumDurationMilliseconds,
                maximumProgressEventCount: 8))
        let revision = ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest())
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v1,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "source.pdf",
            inputPath: ExtractorRelativePath(validating: "input/source.bin"),
            outputPath: ExtractorRelativePath(validating: "output/result.md"),
            deadlineMillisecondsSince1970: 1_900_000_000_000)
        operation = ManagedExtractorProcessRequest(
            revision: revision,
            manifest: manifest,
            protocolRequest: request,
            paths: ManagedExtractorProcessPaths(
                operationRoot: operationRoot,
                packageRoot: packageRoot,
                homeRoot: homeRoot,
                temporaryRoot: temporaryRoot,
                privateCacheRoot: cacheRoot),
            runtimeSearchPolicy: ExtractorRuntimeSearchPolicy(searchDirectories: []),
            cancellationGracePeriod: .milliseconds(50))
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Managed extractor fixture cleanup failed: \(error)") }
    }

    private static func fixtureExecutable() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == "ManagedExtractorFixture",
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw TestFailure("ManagedExtractorFixture is missing")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
