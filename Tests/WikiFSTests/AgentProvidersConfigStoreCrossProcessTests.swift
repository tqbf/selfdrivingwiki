import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct AgentProvidersConfigStoreCrossProcessTests {
    @Test func twoIndependentProcessesPreserveBothMutationsAndGenerationOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-store-processes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Failed to remove the provider-store fixture: \(error)") }
        }
        try AgentProvidersConfig.seed(discovered: []).writeAtomically(to: directory)

        let goURL = directory.appendingPathComponent("go")
        let first = try launchHelper(
            directory: directory,
            readyName: "first-ready",
            goURL: goURL,
            resultName: "first-result",
            providerID: "provider-one",
            modelID: "model-one")
        let second = try launchHelper(
            directory: directory,
            readyName: "second-ready",
            goURL: goURL,
            resultName: "second-result",
            providerID: "provider-two",
            modelID: "model-two")

        try await waitForFiles([first.readyURL, second.readyURL], timeout: .seconds(15))
        try Data().write(to: goURL, options: .atomic)
        async let firstExit: Void = waitForExit(first.process, timeout: .seconds(30))
        async let secondExit: Void = waitForExit(second.process, timeout: .seconds(30))
        try await firstExit
        try await secondExit

        #expect(first.process.terminationStatus == 0)
        #expect(second.process.terminationStatus == 0)
        let loaded = try #require(AgentProvidersConfig.load(from: directory))
        #expect(loaded.selectedModelId(forProvider: ProviderID(rawValue: "provider-one")) == ModelID(rawValue: "model-one"))
        #expect(loaded.selectedModelId(forProvider: ProviderID(rawValue: "provider-two")) == ModelID(rawValue: "model-two"))
        let generations = try [first.resultURL, second.resultURL].map(readGeneration)
        #expect(Set(generations) == [1, 2])
        #expect(loaded.generation == 2)
    }

    @Test func helperHandshakeTimeoutIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-store-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Failed to remove the provider-store fixture: \(error)") }
        }
        try AgentProvidersConfig.seed(discovered: []).writeAtomically(to: directory)
        let helper = try launchHelper(
            directory: directory,
            readyName: "ready",
            goURL: directory.appendingPathComponent("never-created"),
            resultName: "result",
            providerID: "provider",
            modelID: "model")
        try await waitForFiles([helper.readyURL], timeout: .seconds(10))
        await #expect(throws: ProcessWaitError.self) {
            try await waitForExit(helper.process, timeout: .milliseconds(100))
        }
        try await waitForExit(helper.process, timeout: .seconds(5))
        #expect(!helper.process.isRunning)
    }

    private struct HelperProcess {
        let process: Process
        let readyURL: URL
        let resultURL: URL
    }

    private func launchHelper(
        directory: URL,
        readyName: String,
        goURL: URL,
        resultName: String,
        providerID: String,
        modelID: String
    ) throws -> HelperProcess {
        let readyURL = directory.appendingPathComponent(readyName)
        let resultURL = directory.appendingPathComponent(resultName)
        let process = Process()
        process.executableURL = try helperExecutableURL()
        process.arguments = [
            directory.path, readyURL.path, goURL.path, resultURL.path,
            providerID, modelID,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return HelperProcess(process: process, readyURL: readyURL, resultURL: resultURL)
    }

    private func helperExecutableURL() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.lastPathComponent == "ProviderConfigMutationHelper",
                  FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        throw ProcessWaitError.helperNotFound
    }

    private func waitForFiles(_ urls: [URL], timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            guard clock.now < deadline else { throw ProcessWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
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
                guard waiter.finish(.failure(ProcessWaitError.timedOut)) else { return }
                if process.isRunning { process.terminate() }
                throw ProcessWaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func readGeneration(_ url: URL) throws -> UInt64 {
        let value = try String(contentsOf: url, encoding: .utf8)
        return try #require(UInt64(value))
    }
}

private enum ProcessWaitError: Error {
    case helperNotFound
    case timedOut
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let result = lock.withLock { () -> Result<Void, any Error>? in
            if let storedResult = self.result { return storedResult }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
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
