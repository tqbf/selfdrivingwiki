import Foundation
import Testing
@testable import WikiFSCore

struct RendererPackageStoreLayoutTests {
    private let fileSystem = RealRendererPackageFileSystem()

    @Test func injectedRootBuildsVersionedMachinePaths() throws {
        let container = try temporaryDirectory(named: "layout")
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: container)
        let packageID = try RendererPackageID(validating: "org.example.canvas")
        let version = try RendererPackageVersion(validating: "1.2.3-beta.1+build.7")
        let stagingID = try RendererPackageStagingID(validating: "install-42")

        #expect(layout.root.path == container.appendingPathComponent("renderers/v1").path)
        #expect(layout.packageURL(packageID: packageID, version: version).path == layout.root.appendingPathComponent("packages/org.example.canvas/1.2.3-beta.1+build.7").path)
        #expect(layout.stagingURL(stagingID: stagingID).path == layout.root.appendingPathComponent("staging/install-42").path)
        #expect(layout.derivedIndexURL.path == layout.root.appendingPathComponent("derived/index.json").path)
        #expect(layout.lockURL.path == layout.root.appendingPathComponent("store.lock").path)
        #expect(layout.journalURL.path == layout.root.appendingPathComponent("machine.sqlite").path)
        #expect(RendererPackageStagingID(rawValue: "../escape") == nil)
        #expect(RendererPackageStagingID(rawValue: "/absolute") == nil)
    }

    @Test func containmentAcceptsNestedAndRejectsEscapes() throws {
        let root = try temporaryDirectory(named: "containment")
        let nested = root.appendingPathComponent("packages/org.example.canvas/1.0.0")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let sibling = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-sibling")

        #expect(isRendererPackageStorePathContained(nested, within: root))
        #expect(isRendererPackageStorePathContained(root.appendingPathComponent("../outside"), within: root) == false)
        #expect(isRendererPackageStorePathContained(sibling, within: root) == false)
        let nonFileURL = try #require(URL(string: "https://example.com/package"))
        #expect(isRendererPackageStorePathContained(nonFileURL, within: root) == false)
    }

    @Test func containmentRejectsLexicalTraversalWithinRoot() throws {
        let root = try temporaryDirectory(named: "lexical-traversal")
        let nested = root.appendingPathComponent("packages/org.example.canvas/1.0.0")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(isRendererPackageStorePathContained(nested.appendingPathComponent("../escape"), within: root) == false)
    }

    @Test func containmentRejectsResolvedSymlinkEscape() throws {
        let root = try temporaryDirectory(named: "symlink-root")
        let outside = try temporaryDirectory(named: "symlink-outside")
        let target = outside.appendingPathComponent("payload")
        try Data("payload".utf8).write(to: target)
        let link = root.appendingPathComponent("escaped")
        let result = link.path.withCString { linkPath in
            outside.path.withCString { targetPath in
                symlink(targetPath, linkPath)
            }
        }
        #expect(result == 0)

        #expect(isRendererPackageStorePathContained(link.appendingPathComponent("not-yet-created"), within: root) == false)
        #expect(try fileSystem.lstat(at: link).inode != fileSystem.lstat(at: target).inode)
    }

    @Test func fileSystemReportsLstatIdentityAndNoFollowOpen() throws {
        let directory = try temporaryDirectory(named: "identity")
        let file = directory.appendingPathComponent("payload")
        try Data("payload".utf8).write(to: file)
        let identity = try fileSystem.lstat(at: file)
        let descriptor = try fileSystem.openReadOnlyNoFollow(at: file)
        try fileSystem.close(fileDescriptor: descriptor)

        #expect(identity.device > 0)
        #expect(identity.inode > 0)
        #expect(identity.linkCount >= 1)
        #expect(identity.size == 7)
        #expect(identity.mode > 0)
        #expect(identity.modifiedAt <= Date())
        #expect(identity.changedAt <= Date())
    }

    @Test func noFollowOpenRejectsSymlink() throws {
        let directory = try temporaryDirectory(named: "nofollow")
        let target = directory.appendingPathComponent("target")
        try Data("payload".utf8).write(to: target)
        let link = directory.appendingPathComponent("link")
        let result = link.path.withCString { linkPath in
            target.path.withCString { targetPath in
                symlink(targetPath, linkPath)
            }
        }
        #expect(result == 0)

        do {
            _ = try fileSystem.openReadOnlyNoFollow(at: link)
            Issue.record("Expected O_NOFOLLOW to reject a symlink.")
        } catch RendererPackageStoreError.posix(let operation, _, _) {
            #expect(operation == "open")
        } catch {
            Issue.record("Expected a POSIX no-follow error, got: \(error)")
        }
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-package-store-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
