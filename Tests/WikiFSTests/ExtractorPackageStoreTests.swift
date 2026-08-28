import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import WikiFSCore
@testable import WikiFSExtractorStore
import WikiFSTypes

@Suite("Extractor package store", .serialized, .timeLimit(.minutes(2)))
struct ExtractorPackageStoreTests {
    @Test func testingFactoryRejectsReadOnlyRoles() throws {
        for role in [ExtractorPackageProcessRole.daemon, .commandLine] {
            let layout = try makeLayout(role: role)
            #expect(throws: ExtractorPackageStoreError.mutationForbidden) {
                _ = try ExtractorPackageCatalogWriter.testing(layout: layout)
            }
        }
        _ = try ExtractorPackageCatalogWriter.testing(layout: makeLayout(role: .app))
        _ = try ExtractorPackageCatalogWriter.testing(layout: makeLayout(role: .test))
    }

    @Test func daemonAndCLICannotCreateImportStaging() throws {
        for role in [ExtractorPackageProcessRole.daemon, .commandLine] {
            let layout = try makeLayout(role: role)
            #expect(throws: ExtractorDirectoryAdmissionError.mutationForbidden) {
                _ = try ExtractorDirectoryValidator.admit(
                    source: layout.appGroupContainerRoot.appendingPathComponent("source"),
                    layout: layout)
            }
            #expect(FileManager.default.fileExists(atPath: layout.root.path) == false)
        }
    }

    @Test func daemonAndCLIHaveNoMutationTargetDependency() throws {
        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let daemonBlock = try targetBlock(named: "wikid", in: package)
        let cliCoreBlock = try targetBlock(named: "WikiCtlCore", in: package)
        #expect(daemonBlock.contains("WikiFSExtractorStore") == false)
        #expect(cliCoreBlock.contains("WikiFSExtractorStore") == false)
        for path in ["Sources/wikid", "Sources/WikiCtlCore"] {
            let root = repositoryRoot.appendingPathComponent(path, isDirectory: true)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                #expect(try String(
                    contentsOf: file,
                    encoding: .utf8).contains("WikiFSExtractorStore") == false)
            }
        }
    }

    @Test func readerReturnsFreshCatalogWithoutCreatingStore() throws {
        let layout = try makeLayout(role: .daemon)
        let catalog = try ExtractorPackageCatalogReader(layout: layout).read()

        #expect(catalog.generation == 0)
        #expect(catalog.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: layout.root.path) == false)
    }

    @Test func importMovesValidatedBytesAndPublishesOneGeneration() async throws {
        let layout = try makeLayout()
        let fixture = try makeFixture(byte: 1)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)

        let catalog = try await writer.importDirectory(fixture.root, installedAt: timestamp)
        let record = try #require(catalog.records.first)
        let installedURL = layout.packageURL(record.revision.packageID, version: record.revision.version)

        #expect(catalog.generation == 1)
        #expect(record.revision == fixture.revision)
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
        #expect(try ExtractorPackageCatalogReader(layout: layout).read() == catalog)
        #expect(try mode(installedURL.appendingPathComponent("bin/extractor")) == 0o500)
    }

    @Test func repeatedSameRevisionIsIdempotent() async throws {
        let layout = try makeLayout()
        let firstFixture = try makeFixture(byte: 1)
        let secondFixture = try makeFixture(byte: 1)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let first = try await writer.importDirectory(firstFixture.root, installedAt: timestamp)

        let second = try await writer.importDirectory(secondFixture.root, installedAt: timestamp)

        #expect(second == first)
        #expect(second.generation == 1)
        #expect(try FileManager.default.contentsOfDirectory(at: layout.stagingRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func removedReservationRejectsDifferentBytes() async throws {
        let layout = try makeLayout()
        let firstFixture = try makeFixture(byte: 1)
        let conflictingFixture = try makeFixture(byte: 2)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let installed = try await writer.importDirectory(firstFixture.root, installedAt: timestamp)
        let revision = try #require(installed.records.first?.revision)
        let removed = try await writer.remove(revision: revision)

        #expect(removed.generation == 2)
        #expect(removed.records.isEmpty)
        #expect(removed.reservations.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: layout.packagesRoot.appendingPathComponent(revision.packageID.rawValue).path) == false)
        await #expect(throws: ExtractorPackageStoreError.conflictingRevision) {
            try await writer.importDirectory(conflictingFixture.root, installedAt: timestamp)
        }
        #expect(try ExtractorPackageCatalogReader(layout: layout).read() == removed)
    }

    @Test func failedCatalogPublicationLeavesLastGenerationAndMovedTreeForRecovery() async throws {
        let layout = try makeLayout()
        let fixture = try makeFixture(byte: 1)
        let failingWriter = try ExtractorPackageCatalogWriter.testing(
            layout: layout,
            indexWriter: FailingCatalogIndexWriter())

        await #expect(throws: CatalogWriteFailure.self) {
            try await failingWriter.importDirectory(fixture.root, installedAt: timestamp)
        }

        let current = try ExtractorPackageCatalogReader(layout: layout).read()
        #expect(current.generation == 0)
        #expect(current.records.isEmpty)
        let installedURL = layout.packageURL(
            fixture.revision.packageID,
            version: fixture.revision.version)
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
        #expect(try FileManager.default.contentsOfDirectory(
            at: installedURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).map(\.standardizedFileURL.path) == [installedURL.standardizedFileURL.path])
        let recoveredManifest = try JSONDecoder().decode(
            ExtractorManifest.self,
            from: Data(contentsOf: installedURL.appendingPathComponent("manifest.json")))
        #expect(recoveredManifest.packageID == fixture.revision.packageID)
        _ = try ExtractorDirectoryValidator.revalidate(
            root: installedURL,
            within: layout.packagesRoot,
            expectedRevision: fixture.revision)

        let recovered = try await ExtractorPackageCatalogWriter.testing(layout: layout).recover()
        #expect(recovered.generation == 1)
        #expect(recovered.records.map(\.revision) == [fixture.revision])
    }

    @Test func recoveryRemovesInvalidUnreferencedPayloadAndEmptyLineage() async throws {
        let layout = try makeLayout(role: .app)
        let packageID = "org.example.orphan"
        let lineage = layout.packagesRoot.appendingPathComponent(packageID, isDirectory: true)
        let version = lineage.appendingPathComponent("1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: version.appendingPathComponent("manifest.json"))

        _ = try await ExtractorPackageCatalogWriter.testing(layout: layout).recover()

        #expect(FileManager.default.fileExists(atPath: lineage.path) == false)
    }

    @Test func failedStagingIsRemovedByRecovery() async throws {
        let layout = try makeLayout()
        let fixture = try makeFixture(byte: 1)
        ExtractorDirectoryValidator.installSourceEnumerationHookForTesting(source: fixture.root) {
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
        #expect(try FileManager.default.contentsOfDirectory(at: layout.stagingRoot, includingPropertiesForKeys: nil).isEmpty == false)

        ExtractorDirectoryValidator.installSourceEnumerationHookForTesting(
            source: fixture.root,
            nil)
        _ = try await ExtractorPackageCatalogWriter.testing(layout: layout).recover()

        #expect(try FileManager.default.contentsOfDirectory(at: layout.stagingRoot, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func removePublishesBeforePayloadCleanupFailure() async throws {
        let layout = try makeLayout()
        let fixture = try makeFixture(byte: 1)
        let installer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let installed = try await installer.importDirectory(fixture.root, installedAt: timestamp)
        let revision = try #require(installed.records.first?.revision)
        let writer = try ExtractorPackageCatalogWriter.testing(
            layout: layout,
            payloadRemover: FailingPayloadRemover())

        do {
            _ = try await writer.remove(revision: revision)
            Issue.record("Expected payload cleanup to fail")
        } catch ExtractorPackageStoreError.packageRemovalFailed {
            let published = try ExtractorPackageCatalogReader(layout: layout).read()
            #expect(published.records.isEmpty)
            #expect(published.generation == 2)
        }
    }

    @Test func removalRejectsSymlinkedPackageAncestorWithoutTouchingOutside() async throws {
        let layout = try makeLayout()
        let fixture = try makeFixture(byte: 1)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let installed = try await writer.importDirectory(fixture.root, installedAt: timestamp)
        let revision = try #require(installed.records.first?.revision)
        let packageIDRoot = layout.packageURL(
            revision.packageID,
            version: revision.version).deletingLastPathComponent()
        let parked = packageIDRoot.appendingPathExtension("parked")
        try FileManager.default.moveItem(at: packageIDRoot, to: parked)
        let outside = layout.appGroupContainerRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent(revision.version.rawValue)
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        try Data("retain".utf8).write(to: sentinel.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: packageIDRoot, withDestinationURL: outside)

        await #expect(throws: ExtractorPackageStoreError.packageMissing) {
            try await writer.remove(revision: revision)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.appendingPathComponent("sentinel").path))
        #expect(try ExtractorPackageCatalogReader(layout: layout).read().records.isEmpty)
    }

    @Test func recoveryRejectsSymlinkChildrenWithoutTouchingOutside() async throws {
        let layout = try makeLayout(role: .app)
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 0, records: [])
        let outside = layout.appGroupContainerRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("retain".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: layout.stagingRoot.appendingPathComponent("attacker"),
            withDestinationURL: outside)

        await #expect(throws: ExtractorDirectoryAdmissionError.preparationFailed) {
            try await writer.recover()
        }
        #expect(try Data(contentsOf: sentinel) == Data("retain".utf8))
    }

    @Test func staleGenerationDoesNotPublish() async throws {
        let layout = try makeLayout()
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        let first = try await writer.replaceCatalog(expectedGeneration: 0, records: [])
        #expect(first.generation == 1)

        await #expect(throws: ExtractorPackageStoreError.staleGeneration) {
            try await writer.replaceCatalog(expectedGeneration: 0, records: [])
        }
        #expect(try ExtractorPackageCatalogReader(layout: layout).read().generation == 1)
    }

    @Test func corruptAndSymlinkedCatalogsFailClosed() throws {
        let corruptLayout = try makeLayout()
        try FileManager.default.createDirectory(
            at: corruptLayout.derivedRoot,
            withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corruptLayout.derivedIndexURL)
        #expect(throws: ExtractorPackageStoreError.corruptCatalog) {
            _ = try ExtractorPackageCatalogReader(layout: corruptLayout).read()
        }

        let symlinkLayout = try makeLayout()
        try FileManager.default.createDirectory(
            at: symlinkLayout.derivedRoot,
            withIntermediateDirectories: true)
        let outside = symlinkLayout.appGroupContainerRoot.appendingPathComponent("outside-index")
        try JSONEncoder().encode(ExtractorPackageCatalog()).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: symlinkLayout.derivedIndexURL,
            withDestinationURL: outside)
        #expect(throws: ExtractorPackageStoreError.filesystemFailure) {
            _ = try ExtractorPackageCatalogReader(layout: symlinkLayout).read()
        }
    }

    @Test func appRecoveryRemovesStaleAppOperationSessions() async throws {
        let layout = try makeLayout(role: .app)
        let appOperations = layout.operationsRoot.appendingPathComponent("app", isDirectory: true)
        for session in ["invalid-old", "broken"] {
            let operation = appOperations
                .appendingPathComponent(session, isDirectory: true)
                .appendingPathComponent("operation", isDirectory: true)
            try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: operation.appendingPathComponent("input"))
        }

        _ = try await ExtractorPackageCatalogWriter.testing(layout: layout).recover()

        #expect(try FileManager.default.contentsOfDirectory(
            at: appOperations,
            includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func daemonOperationCleanupIsRoleAndSessionScoped() throws {
        let session = ExtractorStagingID(rawValue: "current")!
        let daemonLayout = try makeLayout(role: .daemon, processSessionID: session)
        let appLayout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: daemonLayout.appGroupContainerRoot,
            processRole: .app)
        let currentName = "\(getpid())-\(session.rawValue)"
        let daemonCurrent = daemonLayout.operationsRoot
            .appendingPathComponent("daemon/\(currentName)", isDirectory: true)
        let daemonStale = daemonLayout.operationsRoot
            .appendingPathComponent("daemon/invalid-old", isDirectory: true)
        let appSentinel = appLayout.operationsRoot
            .appendingPathComponent("app/invalid-old", isDirectory: true)
        for root in [daemonCurrent, daemonStale, appSentinel] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("retain".utf8).write(to: root.appendingPathComponent("input"))
        }

        try ExtractorDirectoryValidator.cleanupOperationSessions(
            layout: daemonLayout,
            scope: .staleSessions)
        #expect(FileManager.default.fileExists(atPath: daemonCurrent.path))
        #expect(FileManager.default.fileExists(atPath: daemonStale.path) == false)
        #expect(FileManager.default.fileExists(atPath: appSentinel.path))

        try ExtractorDirectoryValidator.cleanupOperationSessions(
            layout: daemonLayout,
            scope: .currentSession)
        #expect(FileManager.default.fileExists(atPath: daemonCurrent.path) == false)
        #expect(FileManager.default.fileExists(atPath: appSentinel.path))
    }

    @Test func concurrentReadersSeeOnlyCompleteGenerations() async throws {
        let layout = try makeLayout()
        let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 0, records: [])
        let observed = GenerationCollector()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    let generation = try ExtractorPackageCatalogReader(layout: layout).read().generation
                    await observed.append(generation)
                }
            }
            group.addTask {
                _ = try await writer.replaceCatalog(expectedGeneration: 1, records: [])
            }
            try await group.waitForAll()
        }

        #expect(await observed.values.allSatisfy { $0 == 1 || $0 == 2 })
        #expect(try ExtractorPackageCatalogReader(layout: layout).read().generation == 2)
    }

    private let timestamp = RFC3339Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func targetBlock(named name: String, in package: String) throws -> Substring {
        let marker = "name: \"\(name)\""
        let start = try #require(package.range(of: marker)?.lowerBound)
        let remaining = package[start...]
        let end = remaining.range(of: "\n        ),")?.upperBound ?? remaining.endIndex
        return remaining[..<end]
    }

    private func makeLayout(
        role: ExtractorPackageProcessRole = .test,
        processSessionID: ExtractorStagingID = ExtractorStagingID()
    ) throws -> ExtractorPackageStoreLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-store-\(UUID().uuidString)", isDirectory: true)
        return try ExtractorPackageStoreLayout(
            appGroupContainerRoot: root,
            processRole: role,
            processSessionID: processSessionID)
    }

    private func makeFixture(byte: UInt8) throws -> (root: URL, revision: ExtractorPackageRevisionID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-store-fixture-\(UUID().uuidString)", isDirectory: true)
        let entry = root.appendingPathComponent("bin/extractor")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: byte, count: 32)
        try bytes.write(to: entry)
        guard chmod(entry.path, 0o700) == 0 else { throw POSIXError(.EIO) }
        let entryPath = try ExtractorRelativePath(validating: "bin/extractor")
        let manifest = try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: "org.example.store"),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Store Fixture",
            protocolRevision: .v1,
            entryPoint: entryPath,
            launch: .direct,
            registrations: [ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")])],
            capabilities: [],
            files: [ExtractorPackageFile(path: entryPath, digest: ExtractorSHA256.digest(bytes))],
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 1_024,
                maximumMarkdownOutputByteCount: 2_048,
                maximumDurationMilliseconds: 30_000,
                maximumProgressEventCount: 10))
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        return (root, ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest()))
    }

    private func mode(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
        return status.st_mode & 0o7777
    }
}

private actor GenerationCollector {
    private(set) var values: [UInt64] = []

    func append(_ generation: UInt64) {
        values.append(generation)
    }
}

private struct FailingPayloadRemover: ExtractorPackagePayloadRemoving {
    func removePackage(named _: String, from _: Int32) throws {
        throw PayloadRemovalFailure()
    }

    private struct PayloadRemovalFailure: Error {}
}

private struct CatalogWriteFailure: Error {}

private struct FailingCatalogIndexWriter: ExtractorCatalogIndexWriting {
    func replaceAtomically(_: Data, directoryFD _: Int32) throws {
        throw CatalogWriteFailure()
    }
}
