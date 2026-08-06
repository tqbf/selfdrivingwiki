import Foundation
import Testing
import Darwin
@testable import WikiFSCore

@Suite("Renderer directory validation", .serialized, .timeLimit(.minutes(1)))
struct RendererDirectoryValidationTests {
    @Test("valid local directory is staged and hash-pinned")
    func validatesDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validator.validate(directory: fixture.source)
        let expectedHash = try fixture.manifest.packageHash()
        #expect(package.manifest.packageID == fixture.packageID)
        #expect(package.packageHash == expectedHash)
        #expect(FileManager.default.fileExists(atPath: package.stagedRoot.appendingPathComponent("index.html").path))
    }

    @Test("links and special files are rejected")
    func rejectsLinksAndSpecialFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linkPath = fixture.source.appendingPathComponent("linked.html").path
        #expect(symlink("index.html", linkPath) == 0)
        try expectFailure { _ = try fixture.validator.validate(directory: fixture.source) }
        try FileManager.default.removeItem(atPath: linkPath)

        let hardLinkPath = fixture.source.appendingPathComponent("hard.html").path
        #expect(link(fixture.source.appendingPathComponent("index.html").path, hardLinkPath) == 0)
        try expectFailure { _ = try fixture.validator.validate(directory: fixture.source) }

        let fifo = try Fixture()
        defer { fifo.remove() }
        #expect(mkfifo(fifo.source.appendingPathComponent("pipe").path, S_IRUSR | S_IWUSR) == 0)
        try expectFailure { _ = try fifo.validator.validate(directory: fifo.source) }
    }

    @Test("undeclared missing and tampered assets fail closed")
    func rejectsAssetContractViolations() throws {
        let undeclared = try Fixture()
        defer { undeclared.remove() }
        try Data("extra".utf8).write(to: undeclared.source.appendingPathComponent("extra.js"))
        try expectFailure { _ = try undeclared.validator.validate(directory: undeclared.source) }

        let missing = try Fixture()
        defer { missing.remove() }
        try FileManager.default.removeItem(at: missing.source.appendingPathComponent("index.html"))
        try expectFailure { _ = try missing.validator.validate(directory: missing.source) }

        let tampered = try Fixture()
        defer { tampered.remove() }
        try Data("tampered".utf8).write(to: tampered.source.appendingPathComponent("index.html"))
        try expectFailure { _ = try tampered.validator.validate(directory: tampered.source) }

        let hidden = try Fixture()
        defer { hidden.remove() }
        try Data("hidden".utf8).write(to: hidden.source.appendingPathComponent(".hidden.js"))
        try expectValidationFailure(.undeclaredFile(".hidden.js")) {
            _ = try hidden.validator.validate(directory: hidden.source)
        }
    }

    @Test("case-fold collisions and stale staging are rejected or removed")
    func rejectsCollisionAndRecoversStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("different".utf8).write(to: fixture.source.appendingPathComponent("INDEX.html"))
        try expectFailure { _ = try fixture.validator.validate(directory: fixture.source) }

        let stale = fixture.packageRoot.appendingPathComponent(".staging/stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try fixture.validator.recoverStaging()
        #expect(FileManager.default.fileExists(atPath: stale.path) == false)
    }

    @Test("file-count and expected-package-hash limits are enforced")
    func rejectsLimitsAndUnexpectedHash() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for number in 0...RendererPackageValidationLimits.maximumFileCount {
            try Data().write(to: fixture.source.appendingPathComponent("file-\(number)"))
        }
        try expectFailure { _ = try fixture.validator.validate(directory: fixture.source) }

        let fresh = try Fixture()
        defer { fresh.remove() }
        let wrong = RendererSHA256.digest(Data("wrong".utf8))
        try expectFailure { _ = try fresh.validator.validate(directory: fresh.source, expectedHash: wrong) }
    }
}

private final class Fixture {
    let root: URL
    let source: URL
    let packageRoot: URL
    let validator: RendererPackageValidator
    let manifest: RendererManifest
    let packageID: RendererPackageID

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RendererDirectoryValidationTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("candidate", isDirectory: true)
        packageRoot = root.appendingPathComponent("machine-packages", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("<html>renderer</html>".utf8)
        try bytes.write(to: source.appendingPathComponent("index.html"))
        packageID = try RendererPackageID(validating: "org.example.directory-validation")
        let version = try RendererPackageVersion(validating: "1.0.0")
        let registration = try RendererRegistrationID(validating: "viewer")
        let asset = RendererAsset(path: try RendererRelativePath(validating: "index.html"), digest: RendererSHA256.digest(bytes))
        let descriptor = try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: registration),
            displayName: "Directory fixture",
            implementation: .webPackage(.init(path: asset.path)),
            matchers: [.artifactKind(.source)],
            presentations: [.web],
            approvedAssets: [asset],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0
        )
        manifest = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [asset])
        try manifest.canonicalJSON().write(to: source.appendingPathComponent("manifest.json"))
        validator = RendererPackageValidator(packageRoot: packageRoot)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
}

private func expectFailure(_ operation: () throws -> Void) throws {
    do {
        try operation()
        Issue.record("Expected renderer package validation to fail")
    } catch is RendererPackageValidationError {
        // Expected validation boundary failure.
    }
}

private func expectValidationFailure(
    _ expected: RendererPackageValidationError,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("Expected renderer package validation to fail")
    } catch let error as RendererPackageValidationError {
        #expect(error == expected)
    }
}
