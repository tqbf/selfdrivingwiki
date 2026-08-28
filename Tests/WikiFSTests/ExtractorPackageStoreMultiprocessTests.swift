import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSExtractorStore

@Suite("Extractor package store multiprocess", .serialized, .timeLimit(.minutes(2)))
struct ExtractorPackageStoreMultiprocessTests {
    @Test func separateProcessLockExcludesLocalWriterUntilRelease() async throws {
        let root = try temporaryRoot("writer-exclusion")
        let ready = root.appendingPathComponent("ready")
        let release = root.appendingPathComponent("release")
        try await withHelper(arguments: ["hold-lock", root.path, ready.path, release.path]) { helper in
            try await waitForFile(ready, timeout: .seconds(10))
            let layout = try ExtractorPackageStoreLayout(appGroupContainerRoot: root, processRole: .test)
            let coordinator = ExtractorPackageStoreCoordinator(layout: layout)
            let entered = Mutex(false)
            let attempt = LockAttemptProbe()
            let local = Task {
                await attempt.markStarted()
                try await coordinator.withExclusiveAccess {
                    entered.withLock { $0 = true }
                }
            }
            try await waitForAttempt(attempt, timeout: .seconds(5))
            #expect(entered.withLock { $0 } == false)
            try Data().write(to: release, options: .atomic)
            try await waitForExit(helper, timeout: .seconds(15))
            try await local.value
            #expect(helper.terminationStatus == 0)
            #expect(entered.withLock { $0 })
        }
    }

    @Test func storeRootReplacementCannotCreateSecondLockDomain() async throws {
        let root = try temporaryRoot("lock-replacement")
        let ready = root.appendingPathComponent("ready")
        let release = root.appendingPathComponent("release")
        try await withHelper(arguments: ["hold-lock", root.path, ready.path, release.path]) { _ in
            try await waitForFile(ready, timeout: .seconds(10))
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: root,
                processRole: .test)
            let parked = layout.root.appendingPathExtension("parked")
            try FileManager.default.moveItem(at: layout.root, to: parked)
            try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
            let coordinator = ExtractorPackageStoreCoordinator(layout: layout)
            await #expect(throws: ExtractorPackageStoreError.lockTimedOut) {
                try await coordinator.withExclusiveAccess {}
            }
            try Data().write(to: release, options: .atomic)
        }
    }

    @Test func daemonProcessReadsPublishedGeneration() async throws {
        let root = try temporaryRoot("daemon-read")
        let layout = try ExtractorPackageStoreLayout(appGroupContainerRoot: root, processRole: .test)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 0, records: [])
        let result = root.appendingPathComponent("generation")

        try await withHelper(arguments: ["read", root.path, result.path]) { helper in
            try await waitForExit(helper, timeout: .seconds(15))
            #expect(helper.terminationStatus == 0)
            #expect(try String(contentsOf: result, encoding: .utf8) == "1")
        }
    }

    @Test func daemonProcessCannotCreateMutationAuthority() async throws {
        let root = try temporaryRoot("daemon-mutation")
        try await withHelper(arguments: ["daemon-mutate", root.path]) { helper in
            try await waitForExit(helper, timeout: .seconds(15))
            #expect(helper.terminationStatus == 0)
        }
    }

    @Test func writerCrashReleasesKernelLockForFreshWriter() async throws {
        let root = try temporaryRoot("writer-crash")
        let ready = root.appendingPathComponent("crash-ready")
        try await withHelper(arguments: ["crash-with-lock", root.path, ready.path]) { helper in
            try await waitForFile(ready, timeout: .seconds(10))
            try await waitForExit(helper, timeout: .seconds(10))
            #expect(helper.terminationStatus == 91)
        }
        let layout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: root,
            processRole: .test)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let catalog = try await writer.replaceCatalog(expectedGeneration: 0, records: [])
        #expect(catalog.generation == 1)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-process-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func withHelper<T: Sendable>(
        arguments: [String],
        operation: (Process) async throws -> T
    ) async throws -> T {
        let process = try launchHelper(arguments: arguments)
        do {
            let value = try await operation(process)
            try await stopHelperIfNeeded(process)
            return value
        } catch {
            do { try await stopHelperIfNeeded(process) }
            catch { Issue.record("Extractor helper cleanup failed") }
            throw error
        }
    }

    private func stopHelperIfNeeded(_ process: Process) async throws {
        guard process.isRunning else { return }
        process.terminate()
        try await waitForExit(process, timeout: .seconds(5), terminateOnTimeout: false)
    }

    private func launchHelper(arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = try helperExecutableURL()
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
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
            guard candidate.lastPathComponent == "ExtractorPackageStoreProcessHelper",
                  FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate
        }
        throw MultiprocessTestError.helperNotFound
    }

    private func waitForAttempt(_ probe: LockAttemptProbe, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await probe.started == false {
            guard clock.now < deadline else { throw MultiprocessTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForFile(_ url: URL, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while FileManager.default.fileExists(atPath: url.path) == false {
            guard clock.now < deadline else { throw MultiprocessTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForExit(
        _ process: Process,
        timeout: Duration,
        terminateOnTimeout: Bool = true
    ) async throws {
        let waiter = MultiprocessExitWaiter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        waiter.install(continuation)
                        process.terminationHandler = { _ in waiter.finish(.success(())) }
                        if process.isRunning == false { waiter.finish(.success(())) }
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
                guard waiter.finish(.failure(MultiprocessTestError.timedOut)) else { return }
                if terminateOnTimeout, process.isRunning { process.terminate() }
                throw MultiprocessTestError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private actor LockAttemptProbe {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}

private enum MultiprocessTestError: Error {
    case helperNotFound
    case timedOut
}

private final class MultiprocessExitWaiter: @unchecked Sendable {
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
