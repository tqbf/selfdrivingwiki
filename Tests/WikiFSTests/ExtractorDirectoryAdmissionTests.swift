import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

@Suite("Extractor directory admission", .serialized)
struct ExtractorDirectoryAdmissionTests {
    @Test func layoutAndIDsAreSafeComponents() throws {
        let layout = try makeLayout()
        #expect(layout.root.path.hasSuffix("extractors/v1"))
        #expect(layout.derivedIndexURL.lastPathComponent == "index.json")
        #expect(ExtractorStagingID(rawValue: "../escape") == nil)
        #expect(ExtractorOperationID(rawValue: "a/b") == nil)
        let safe = try #require(ExtractorStagingID(rawValue: "safe"))
        #expect(layout.stagingURL(safe).path.hasSuffix("staging/safe"))
    }

    @Test func sourceFileIsRejected() throws {
        let source = uniqueURL("source-file")
        try Data("not a directory".utf8).write(to: source)
        #expect(throws: ExtractorDirectoryAdmissionError.sourceNotDirectory) {
            _ = try ExtractorDirectoryValidator.admit(source: source, layout: makeLayout())
        }
    }

    @Test func directEntryRequiresOwnerExecute() throws {
        let fixture = try makeFixture(launch: .direct, entryMode: 0o400)
        #expect(throws: ExtractorDirectoryAdmissionError.manifest(.directEntryPointIsNotOwnerExecutable)) {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
        }
    }

    @Test func directEntryOutsideBinGetsExecutableNormalizedMode() throws {
        let fixture = try makeFixture(launch: .direct, entryPath: "scripts/run", entryMode: 0o700)
        let admitted = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
        #expect(try mode(admitted.root.appendingPathComponent("scripts/run")) == 0o500)
        #expect(try mode(admitted.root.appendingPathComponent("scripts")) == 0o700)
    }

    @Test func runtimeEntryGetsReadOnlyMode() throws {
        let fixture = try makeFixture(launch: .runtime(command: ExtractorRuntimeName(validating: "bun"), arguments: []), entryMode: 0o700)
        let admitted = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
        #expect(try mode(admitted.root.appendingPathComponent("bin/extractor")) == 0o400)
    }

    @Test func symlinkIsRejected() throws {
        let fixture = try makeFixture()
        let entry = fixture.root.appendingPathComponent("bin/extractor")
        try FileManager.default.removeItem(at: entry)
        let target = fixture.root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
        #expect(throws: ExtractorDirectoryAdmissionError.symlink("bin/extractor")) {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
        }
    }

    @Test func hardLinkIsRejected() throws {
        let fixture = try makeFixture()
        let second = fixture.root.appendingPathComponent("bin/alias")
        #if canImport(Darwin)
        guard link(fixture.root.appendingPathComponent("bin/extractor").path, second.path) == 0 else { throw POSIXError(.EIO) }
        #else
        #expect(Bool(false), "hard-link coverage is macOS-only")
        return
        #endif
        do {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
            Issue.record("hard link was admitted")
        } catch let error as ExtractorDirectoryAdmissionError {
            guard case .hardLink(let path) = error else { Issue.record("unexpected error: \(error)"); return }
            #expect(["bin/alias", "bin/extractor"].contains(path))
        }
    }

    #if canImport(Darwin)
    @Test func fifoIsRejected() throws {
        let fixture = try makeFixture()
        let fifo = fixture.root.appendingPathComponent("bin/fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        #expect(throws: ExtractorDirectoryAdmissionError.specialFile("bin/fifo")) {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
        }
    }
    #endif

    @Test func caseAndUnicodeCollisionsAreRejected() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("bin/a"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("bin/á"), withIntermediateDirectories: false)
        try expectCollision(fixture.root, paths: ["bin/a", "bin/á"])
    }

    private func expectCollision(_ root: URL, paths: [String]) throws {
        do {
            _ = try ExtractorDirectoryValidator.admit(source: root, layout: makeLayout())
            Issue.record("normalized collision was admitted")
        } catch let error as ExtractorDirectoryAdmissionError {
            guard case .collision(let path) = error else { Issue.record("unexpected error: \(error)"); return }
            #expect(paths.contains(path))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func manifestErrorsRemainAuthoritative() throws {
        let undeclared = try makeFixture(extraFiles: [("extra.txt", Data("extra".utf8))])
        #expect(throws: ExtractorDirectoryAdmissionError.manifest(.undeclaredFile("extra.txt"))) {
            _ = try ExtractorDirectoryValidator.admit(source: undeclared.root, layout: makeLayout())
        }
        let changed = try makeFixture()
        try Data("changed".utf8).write(to: changed.root.appendingPathComponent("bin/extractor"))
        #expect(throws: ExtractorDirectoryAdmissionError.manifest(.fileDigestMismatch("bin/extractor"))) {
            _ = try ExtractorDirectoryValidator.admit(source: changed.root, layout: makeLayout())
        }
    }

    @Test func revalidationRejectsModeDriftAndContainmentEscape() throws {
        let fixture = try makeFixture()
        let layout = try makeLayout()
        let admitted = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: layout)
        let expected = admitted.revisionID
        let entry = admitted.root.appendingPathComponent("bin/extractor")
        #if canImport(Darwin)
        guard chmod(entry.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        #else
        Issue.record("mode drift coverage is macOS-only")
        #endif
        #expect(throws: ExtractorDirectoryAdmissionError.modeChanged("bin/extractor")) {
            _ = try ExtractorDirectoryValidator.revalidate(root: admitted.root, within: layout.stagingRoot, expectedRevision: expected)
        }
        #expect(throws: ExtractorDirectoryAdmissionError.containment) {
            _ = try ExtractorDirectoryValidator.revalidate(root: fixture.root, within: layout.stagingRoot, expectedRevision: expected)
        }
    }

    @Test func snapshotUsesExactInstalledPackageAndProcessContainment() throws {
        let fixture = try makeFixture()
        let layout = try makeLayout()
        let admitted = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: layout)
        let packageRoot = layout.packageURL(fixture.manifest.packageID, version: fixture.manifest.version)
        try FileManager.default.createDirectory(at: packageRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: admitted.root, to: packageRoot)
        let snapshot = try ExtractorDirectoryValidator.snapshot(installedRoot: packageRoot, expectedRevision: admitted.revisionID, layout: layout)
        #expect(snapshot.root.standardizedFileURL.path.hasPrefix(layout.processOperationsRoot.standardizedFileURL.path + "/"))
        #expect(snapshot.revisionID == admitted.revisionID)
        #expect(try mode(snapshot.root) == 0o700)
        #expect(try mode(snapshot.root.appendingPathComponent("bin")) == 0o700)
        #expect(try mode(snapshot.root.appendingPathComponent("bin/extractor")) == 0o500)
    }

    @Test func operationPackageMaterializationPinsValidatedBytes() throws {
        let fixture = try makeFixture()
        let layout = try makeLayout()
        let admitted = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: layout)

        let operationRoot = uniqueURL("operation")
        try FileManager.default.createDirectory(
            at: operationRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let target = operationRoot.appendingPathComponent("package", isDirectory: true)
        let revision = try ExtractorDirectoryValidator.materializeOperationPackage(
            from: admitted,
            into: target)

        #expect(revision == admitted.revisionID)
        #expect(try mode(target) == 0o700)
        #expect(try mode(target.appendingPathComponent("bin")) == 0o700)
        #expect(try mode(target.appendingPathComponent("bin/extractor")) == 0o500)
        #expect(throws: ExtractorDirectoryAdmissionError.preparationFailed) {
            _ = try ExtractorDirectoryValidator.materializeOperationPackage(
                from: admitted,
                into: target)
        }
    }

    @Test func symlinkedStagingAncestorIsRejected() throws {
        let fixture = try makeFixture()
        let layout = try makeLayout()
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let redirect = uniqueURL("redirect").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: redirect, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: layout.stagingRoot, withDestinationURL: redirect)
        #expect(throws: ExtractorDirectoryAdmissionError.preparationFailed) {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: layout)
        }
    }

    @Test func sourceDirectoryMetadataChangeDuringEnumerationIsRejected() throws {
        let fixture = try makeFixture()
        let injected = Mutex(false)
        ExtractorDirectoryValidator.installSourceEnumerationHookForTesting(source: fixture.root) {
            let mustInject = injected.withLock { value in
                guard value == false else { return false }
                value = true
                return true
            }
            guard mustInject else { return }
            guard chmod(fixture.root.path, 0o711) == 0 else { throw POSIXError(.EIO) }
        }
        defer {
            ExtractorDirectoryValidator.installSourceEnumerationHookForTesting(
                source: fixture.root,
                nil)
        }
        #expect(throws: ExtractorDirectoryAdmissionError.sourceChanged) {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: makeLayout())
        }
    }

    @Test func failedStagingRemainsForSerializedRecovery() throws {
        let fixture = try makeFixture()
        let layout = try makeLayout()
        let markerName = "substitute-marker"
        ExtractorDirectoryValidator.installSourceEnumerationHookForTesting(source: fixture.root) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: layout.stagingRoot,
                includingPropertiesForKeys: nil)
            guard let destination = entries.first else {
                throw ExtractorDirectoryAdmissionError.preparationFailed
            }
            let parked = destination.appendingPathExtension("parked")
            try FileManager.default.moveItem(at: destination, to: parked)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("retain".utf8).write(to: destination.appendingPathComponent(markerName))
            throw ExtractorDirectoryAdmissionError.sourceChanged
        }
        defer {
            ExtractorDirectoryValidator.installSourceEnumerationHookForTesting(
                source: fixture.root,
                nil)
        }

        #expect(throws: ExtractorDirectoryAdmissionError.sourceChanged) {
            _ = try ExtractorDirectoryValidator.admit(source: fixture.root, layout: layout)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: layout.stagingRoot,
            includingPropertiesForKeys: nil)
        let substitutedDirectories = entries.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(markerName).path)
        }
        #expect(substitutedDirectories.count == 1)
    }

    private func makeLayout() throws -> ExtractorPackageStoreLayout {
        try ExtractorPackageStoreLayout(appGroupContainerRoot: uniqueURL("layout"))
    }

    private func uniqueURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-admission-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func mode(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
        return status.st_mode & 0o7777
    }

    private func makeFixture(
        launch: ExtractorLaunch = .direct,
        entryPath: String = "bin/extractor",
        entryMode: mode_t = 0o700,
        extraFiles: [(String, Data)] = []) throws -> (root: URL, manifest: ExtractorManifest) {
        let root = uniqueURL("fixture")
        let entry = root.appendingPathComponent(entryPath)
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("fixture".utf8)
        try bytes.write(to: entry)
        #if canImport(Darwin)
        guard chmod(entry.path, entryMode) == 0 else { throw POSIXError(.EIO) }
        #endif
        for (path, data) in extraFiles {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let relativeEntry = try ExtractorRelativePath(validating: entryPath)
        let manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.fixture"),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Fixture", protocolRevision: .v1,
            entryPoint: relativeEntry, launch: launch,
            registrations: [ExtractorRegistration(id: ExtractorRegistrationID(validating: "main"), displayName: "Main", kinds: [.pdf], mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(path: relativeEntry, digest: ExtractorSHA256.digest(bytes))],
            limits: ExtractorOperationLimits(maximumInputByteCount: 1_024, maximumMarkdownOutputByteCount: 2_048, maximumDurationMilliseconds: 30_000, maximumProgressEventCount: 10))
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        return (root, manifest)
    }
}
