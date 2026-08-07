import Foundation
import Testing
@testable import WikiFSCore

@Suite("Renderer package resource provider", .serialized, .timeLimit(.minutes(1)))
struct RendererPackageResourceProviderTests {
    @Test("serves a declared version-pinned asset through the package scheme")
    func servesDeclaredAsset() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }

        let resource = try fixture.provider().resource(for: fixture.entryURL)

        #expect(resource.data == fixture.entryData)
        #expect(resource.mimeType.rawValue == "text/html")
        #expect(resource.isEntryDocument)
    }

    @Test("denies a mismatched identity, traversal, and undeclared asset")
    func deniesInvalidRequests() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let otherID = try RendererPackageID(validating: "org.example.other")
        let declaredPath = try RendererRelativePath(validating: "index.html")
        let mismatched = RendererPackageScheme.url(packageID: otherID, version: fixture.version, path: declaredPath)
        try expectResourceFailure(.packageIdentityMismatch) { _ = try fixture.provider().resource(for: mismatched) }

        let traversal = try #require(URL(string: "\(RendererPackageScheme.name)://package/\(fixture.packageID.rawValue)/\(fixture.version.rawValue)/%2E%2E/index.html"))
        try expectResourceFailure(.invalidRequest) { _ = try fixture.provider().resource(for: traversal) }

        let undeclared = RendererPackageScheme.url(
            packageID: fixture.packageID,
            version: fixture.version,
            path: try RendererRelativePath(validating: "not-declared.js")
        )
        try expectResourceFailure(.undeclaredAsset) { _ = try fixture.provider().resource(for: undeclared) }
    }

    @Test("a fresh digest rejects a changed installed asset")
    func deniesHashChangedAsset() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let provider = try fixture.provider()
        try Data("changed".utf8).write(to: fixture.entryURLOnDisk)

        try expectResourceFailure(.assetHashMismatch) { _ = try provider.resource(for: fixture.entryURL) }
    }

    @Test("identity change between lstat and open fails closed")
    func deniesReplacementDuringOpen() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let real = RealRendererPackageFileSystem()
        let original = try real.lstat(at: fixture.entryURLOnDisk)
        let replacementURL = fixture.root.appendingPathComponent("replacement.html")
        try Data("replacement".utf8).write(to: replacementURL)
        let replacement = try real.lstat(at: replacementURL)
        let provider = try fixture.provider(fileSystem: ReplacingFileSystem(before: original, opened: replacement, data: fixture.entryData))

        try expectResourceFailure(.filesystemChanged) { _ = try provider.resource(for: fixture.entryURL) }
    }
}

private struct ResourceFixture {
    let root: URL
    let packageRoot: URL
    let packageID: RendererPackageID
    let version: RendererPackageVersion
    let expectedHash: RendererSHA256Digest
    let entryData: Data
    let entryURLOnDisk: URL
    let entryURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RendererPackageResourceProviderTests-\(UUID().uuidString)", isDirectory: true)
        packageRoot = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        packageID = try RendererPackageID(validating: "org.example.resource-provider")
        version = try RendererPackageVersion(validating: "1.0.0")
        entryData = Data("<html><body>renderer</body></html>".utf8)
        entryURLOnDisk = packageRoot.appendingPathComponent("index.html")
        try entryData.write(to: entryURLOnDisk)
        let asset = RendererAsset(path: try RendererRelativePath(validating: "index.html"), digest: RendererSHA256.digest(entryData))
        let descriptor = try RendererDescriptor(
            reference: .init(packageID: packageID, version: version, registrationID: try RendererRegistrationID(validating: "viewer")),
            displayName: "Resource fixture",
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
        let manifest = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [asset])
        expectedHash = try manifest.packageHash()
        try manifest.canonicalJSON().write(to: packageRoot.appendingPathComponent("manifest.json"))
        entryURL = RendererPackageScheme.url(packageID: packageID, version: version, path: asset.path)
    }

    func provider(fileSystem: any RendererPackageFileSystem = RealRendererPackageFileSystem()) throws -> ValidatedRendererPackageResourceProvider {
        try ValidatedRendererPackageResourceProvider(
            packageID: packageID,
            version: version,
            expectedPackageHash: expectedHash,
            installedRoot: packageRoot,
            validator: RendererPackageValidator(packageRoot: root),
            fileSystem: fileSystem
        )
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
}

private struct ReplacingFileSystem: RendererPackageFileSystem {
    let before: RendererPackageFileIdentity
    let opened: RendererPackageFileIdentity
    let data: Data

    func ensureDirectory(at url: URL) throws {}
    func lstat(at url: URL) throws -> RendererPackageFileIdentity { before }
    func openReadOnlyNoFollow(at url: URL) throws -> Int32 { 1 }
    func fileIdentity(fileDescriptor: Int32) throws -> RendererPackageFileIdentity { opened }
    func readAll(fileDescriptor: Int32, maximumBytes: Int) throws -> Data { data }
    func createExclusiveFile(at url: URL, contents: Data) throws -> RendererPackageFileIdentity { before }
    func openLockFileNoFollow(at url: URL) throws -> Int32 { 1 }
    func createExclusiveLockFile(at url: URL, contents: Data) throws -> Int32 { 1 }
    func lockExclusiveNonblocking(fileDescriptor: Int32) throws {}
    func unlock(fileDescriptor: Int32) throws {}
    func createHardLink(from source: URL, to destination: URL) throws {}
    func removeFile(at url: URL) throws {}
    func close(fileDescriptor: Int32) throws {}
}

private func expectResourceFailure(
    _ expected: RendererPackageResourceError,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
        Issue.record("Expected renderer package resource request to fail")
    } catch let error as RendererPackageResourceError {
        #expect(error == expected)
    }
}
