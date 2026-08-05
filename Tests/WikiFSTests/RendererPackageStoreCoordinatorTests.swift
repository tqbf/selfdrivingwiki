import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererPackageStoreCoordinatorTests {
    @Test func stableLockInodeSurvivesReleaseAndSerializesOwners() async throws {
        let layout = try makeLayout("stable-inode")
        let first = coordinator(layout: layout, token: "11111111-1111-1111-1111-111111111111")
        let second = coordinator(layout: layout, token: "22222222-2222-2222-2222-222222222222")
        try await first.withExclusiveAccess {}
        let identity = try RealRendererPackageFileSystem().lstat(at: layout.lockURL)
        try await second.withExclusiveAccess {}
        #expect(try RealRendererPackageFileSystem().lstat(at: layout.lockURL).refersToSameObject(as: identity))
    }

    @Test func cooperativeReleaseLetsAnotherCoordinatorAcquireStableInode() async throws {
        let layout = try makeLayout("retry")
        let fileSystem = RealRendererPackageFileSystem()
        try fileSystem.ensureDirectory(at: layout.root)
        let descriptor = try fileSystem.createExclusiveLockFile(at: layout.lockURL, contents: Data())
        try fileSystem.lockExclusiveNonblocking(fileDescriptor: descriptor)
        try fileSystem.unlock(fileDescriptor: descriptor)
        try fileSystem.close(fileDescriptor: descriptor)
        let subject = RendererPackageStoreCoordinator(layout: layout, tokenGenerator: FixedToken(value: "33333333-3333-3333-3333-333333333333"))
        try await subject.withExclusiveAccess {}
    }

    @Test func separateOpenFileDescriptionsCannotAcquireKernelLockUntilRelease() throws {
        let layout = try makeLayout("kernel-contention")
        let fileSystem = RealRendererPackageFileSystem()
        try fileSystem.ensureDirectory(at: layout.root)
        let first = try fileSystem.createExclusiveLockFile(at: layout.lockURL, contents: Data())
        defer { closeIgnoringFailure(fileSystem, descriptor: first) }
        let second = try fileSystem.openLockFileNoFollow(at: layout.lockURL)
        defer { closeIgnoringFailure(fileSystem, descriptor: second) }

        try fileSystem.lockExclusiveNonblocking(fileDescriptor: first)
        #expect(throws: RendererPackageStoreError.self) {
            try fileSystem.lockExclusiveNonblocking(fileDescriptor: second)
        }
        try fileSystem.unlock(fileDescriptor: first)
        try fileSystem.lockExclusiveNonblocking(fileDescriptor: second)
        try fileSystem.unlock(fileDescriptor: second)
    }

    @Test func distinctCoordinatorsForOneLayoutCannotEnterConcurrently() async throws {
        let layout = try makeLayout("in-process-contention")
        let first = coordinator(layout: layout, token: "66666666-6666-6666-6666-666666666666")
        let second = coordinator(layout: layout, token: "77777777-7777-7777-7777-777777777777")
        let probe = CoordinatorContentionProbe()

        let firstTask = Task {
            try await first.withExclusiveAccess {
                await probe.recordFirstEntry()
                try await probe.waitForRelease()
            }
        }
        try await waitUntil("first coordinator entry") { await probe.firstEntered }
        let secondTask = Task {
            await probe.recordSecondAttempt()
            try await second.withExclusiveAccess {
                await probe.recordSecondEntry()
            }
        }
        try await waitUntil("second coordinator attempt") { await probe.secondAttempted }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.secondEntered == false)

        await probe.allowFirstToFinish()
        try await firstTask.value
        try await secondTask.value
        #expect(await probe.secondEntered)
    }

    @Test func malformedDiagnosticMetadataDoesNotBlockKernelRecovery() async throws {
        let layout = try makeLayout("metadata")
        let filesystem = RealRendererPackageFileSystem()
        try filesystem.ensureDirectory(at: layout.root)
        let descriptor = try filesystem.createExclusiveLockFile(at: layout.lockURL, contents: Data("not-json".utf8))
        try filesystem.close(fileDescriptor: descriptor)
        let subject = coordinator(layout: layout, token: "44444444-4444-4444-4444-444444444444")
        try await subject.withExclusiveAccess {}
        #expect(try filesystem.lstat(at: layout.lockURL).size > 0)
    }

    @Test func symlinkLockFailsClosed() async throws {
        let layout = try makeLayout("symlink")
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.lockURL, withDestinationURL: layout.root)
        let subject = coordinator(layout: layout, token: "55555555-5555-5555-5555-555555555555")
        await #expect(throws: RendererCoordinatorFailure.filesystemOperationFailed) { try await subject.withExclusiveAccess {} }
    }

    private func makeLayout(_ name: String) throws -> RendererPackageStoreLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-coordinator-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try RendererPackageStoreLayout(appGroupContainerRoot: root)
    }

    private func coordinator(layout: RendererPackageStoreLayout, token: String) -> RendererPackageStoreCoordinator {
        RendererPackageStoreCoordinator(layout: layout, processIdentity: RendererProcessIdentity(processID: 42, executableIdentity: "test", hostIdentity: "test-host", bootSessionIdentity: nil), tokenGenerator: FixedToken(value: token))
    }
}

private struct FixedToken: RendererCoordinatorOwnerTokenGenerating { let value: String; func nextOwnerToken() -> String { value } }

private enum CoordinatorTestFailure: Error { case timedOut }

private actor CoordinatorContentionProbe {
    private(set) var firstEntered = false
    private(set) var secondAttempted = false
    private(set) var secondEntered = false
    private var firstMayFinish = false

    func recordFirstEntry() { firstEntered = true }
    func recordSecondAttempt() { secondAttempted = true }
    func recordSecondEntry() { secondEntered = true }
    func allowFirstToFinish() { firstMayFinish = true }

    func waitForRelease() async throws {
        while firstMayFinish == false {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func waitUntil(_ description: String, condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw CoordinatorTestFailure.timedOut
}

private func closeIgnoringFailure(_ fileSystem: RealRendererPackageFileSystem, descriptor: Int32) {
    do { try fileSystem.close(fileDescriptor: descriptor) }
    catch { DebugLog.store("Renderer coordinator test descriptor close failed.") }
}
