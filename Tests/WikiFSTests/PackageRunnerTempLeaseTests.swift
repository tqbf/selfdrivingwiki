import Foundation
import Testing
@testable import WikiFSEngine

/// Filesystem contract of the package-runner staging lease (issue #1279):
/// unique pre-created directories, rollback on partial allocation failure,
/// and cleanup that removes ONLY the owned directory.
@Suite("PackageRunnerTempLease")
struct PackageRunnerTempLeaseTests {

    /// An isolated root so sibling suites running concurrently cannot
    /// interfere with the existence assertions.
    private func isolatedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Lease directory exists before use and is under the requested parent")
    func allocatedDirectoryExistsBeforeUse() throws {
        let root = try isolatedRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let lease = try PackageRunnerTempLease.make(parent: root.appendingPathComponent("wikifs-tmp"))
        defer { lease.remove() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: lease.directoryURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(lease.directoryURL.deletingLastPathComponent().lastPathComponent == "wikifs-tmp")
    }

    @Test("Two allocations get different UUID paths")
    func allocationsAreUnique() throws {
        let root = try isolatedRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let first = try PackageRunnerTempLease.make(parent: root)
        let second = try PackageRunnerTempLease.make(parent: root)
        defer {
            first.remove()
            second.remove()
        }
        #expect(first.directoryURL.path != second.directoryURL.path)
        #expect(FileManager.default.fileExists(atPath: first.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: second.directoryURL.path))
    }

    @Test("Cleanup removes only the owned UUID directory")
    func cleanupRemovesOnlyOwnedDirectory() throws {
        let root = try isolatedRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        let lease = try PackageRunnerTempLease.make(parent: root)
        let sibling = try PackageRunnerTempLease.make(parent: root)
        defer { sibling.remove() }
        // A file INSIDE the lease (what bun staging would leave behind).
        try Data("staged".utf8).write(to: lease.directoryURL.appendingPathComponent("entry.js"))

        lease.remove()

        #expect(!FileManager.default.fileExists(atPath: lease.directoryURL.path))
        #expect(FileManager.default.fileExists(atPath: sibling.directoryURL.path),
                "a sibling lease must survive")
        #expect(FileManager.default.fileExists(atPath: root.path),
                "the parent root must survive")
    }

    @Test("Partial allocation failure rolls back the parent this attempt created")
    func allocationFailureRollsBackCreatedParent() throws {
        let root = try isolatedRoot()
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("lease root cleanup failed: \(error)") }
        }
        // An UNCREATABLE child: the "parent" candidate under root is a plain
        // FILE, so creating the wikifs-tmp leaf under it must fail. The
        // attempt created nothing under `root` that survives.
        let blockingFile = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blockingFile)

        #expect(throws: (any Error).self) {
            _ = try PackageRunnerTempLease.make(parent: blockingFile.appendingPathComponent("wikifs-tmp"))
        }
        // Nothing new appeared next to the blocker.
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(contents.map(\.lastPathComponent) == ["blocker"],
                "a failed allocation must leave nothing behind, got \(contents.map(\.lastPathComponent))")
    }

    @Test("The production default parent sits under the Bun home")
    func defaultParentIsUnderBunHome() {
        let parent = PackageRunnerTempLease.defaultParent(homePath: "/Users/someone")
        #expect(parent.path == "/Users/someone/.bun/wikifs-tmp")
        // The lease must NEVER default into the shared process temporary
        // directory — that is the LLMSandboxScratch world, W^X under strict.
        let processTemp = FileManager.default.temporaryDirectory.path
        #expect(!parent.path.hasPrefix(processTemp),
                "the default lease parent must not live under the shared temp root")
    }
}
