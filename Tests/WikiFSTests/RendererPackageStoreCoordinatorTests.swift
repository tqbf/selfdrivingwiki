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
