#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import wikid

@Suite("Daemon wiki creation coordinator", .serialized, .timeLimit(.minutes(1)))
struct DaemonWikiCreationCoordinatorTests {
    private struct ExpectedFailure: Error {}

    @Test("registry save failure removes database artifacts")
    func registrySaveFailureRemovesDatabaseArtifacts() async throws {
        let directory = temporaryDirectory()
        let removed = LockedWikiIDs()
        let coordinator = DaemonWikiCreationCoordinator(
            containerDirectory: directory,
            bootstrap: StoreBootstrap(),
            persistDescriptor: { _ in throw ExpectedFailure() },
            removeDescriptor: { _ in Issue.record("registry was never persisted") },
            prepareProfile: { _ in Issue.record("profile preparation must not start") },
            removeProfile: { _ in Issue.record("profile was never prepared") },
            deleteArtifacts: { wikiID in
                removed.append(wikiID)
                try removeArtifacts(directory: directory, wikiID: wikiID)
            })

        await #expect(throws: ExpectedFailure.self) {
            _ = try await coordinator.createWiki(name: "Failure")
        }
        let wikiID = try #require(removed.values.first)
        #expect(!FileManager.default.fileExists(atPath: databaseURL(directory: directory, wikiID: wikiID).path))
    }

    @Test("profile failure rolls registry back and removes artifacts")
    func profileFailureRollsBack() async throws {
        let directory = temporaryDirectory()
        let persisted = LockedWikiIDs()
        let removed = LockedWikiIDs()
        let coordinator = DaemonWikiCreationCoordinator(
            containerDirectory: directory,
            bootstrap: StoreBootstrap(),
            persistDescriptor: { persisted.append($0.id) },
            removeDescriptor: { removed.append($0) },
            prepareProfile: { _ in throw ExpectedFailure() },
            removeProfile: { _ in },
            deleteArtifacts: { try removeArtifacts(directory: directory, wikiID: $0) })

        await #expect(throws: ExpectedFailure.self) {
            _ = try await coordinator.createWiki(name: "Failure")
        }
        #expect(persisted.values == removed.values)
        let wikiID = try #require(persisted.values.first)
        #expect(!FileManager.default.fileExists(atPath: databaseURL(directory: directory, wikiID: wikiID).path))
    }

    @Test("shutdown rejects creation")
    func shutdownRejectsCreation() async throws {
        let coordinator = DaemonWikiCreationCoordinator(
            containerDirectory: temporaryDirectory(),
            bootstrap: StoreBootstrap(),
            persistDescriptor: { _ in },
            removeDescriptor: { _ in },
            prepareProfile: { _ in },
            removeProfile: { _ in },
            deleteArtifacts: { _ in })
        await coordinator.beginShutdown()

        await #expect(throws: DaemonWikiCreationError.self) {
            _ = try await coordinator.createWiki(name: "Rejected")
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-create-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class LockedWikiIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WikiID] = []
    var values: [WikiID] { lock.withLock { storage } }
    func append(_ wikiID: WikiID) { lock.withLock { storage.append(wikiID) } }
}

private func databaseURL(directory: URL, wikiID: WikiID) -> URL {
    directory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
}

private func removeArtifacts(directory: URL, wikiID: WikiID) throws {
    let base = databaseURL(directory: directory, wikiID: wikiID).path
    for suffix in ["", "-wal", "-shm"] {
        let path = base + suffix
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
#endif
