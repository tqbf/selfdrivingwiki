#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import WikiFSCore

@Suite("Renderer package activation", .serialized, .timeLimit(.minutes(1)))
struct RendererPackageActivationTests {
    @Test func successfulActivationMovesValidatedPackageAndProjectsDescriptors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()

        let index = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)

        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)
        #expect(index.generation == 1)
        #expect(index.records.map(\.state) == [.validated])
        #expect(index.availableDescriptorProjection == fixture.manifest.descriptors)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: package.stagedRoot.path) == false)
    }

    @Test("the machine index rejects two active versions of one logical renderer")
    func machineIndexRejectsDuplicateActiveLogicalRenderer() throws {
        let packageID = try RendererPackageID(validating: "org.example.logical")
        let firstVersion = try RendererPackageVersion(validating: "1.0.0")
        let secondVersion = try RendererPackageVersion(validating: "1.0.1")
        let firstManifest = try Fixture.makeManifest(
            packageID: packageID,
            version: firstVersion,
            contents: Data("first renderer".utf8))
        let secondManifest = try Fixture.makeManifest(
            packageID: packageID,
            version: secondVersion,
            contents: Data("second renderer".utf8))
        let timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        let firstRecord = try RendererPackageInstallRecord(
            packageID: packageID,
            version: firstVersion,
            expectedPackageHash: try firstManifest.packageHash(),
            state: .validated,
            reservedAt: timestamp,
            updatedAt: timestamp,
            validatedDescriptors: firstManifest.descriptors)
        let secondRecord = try RendererPackageInstallRecord(
            packageID: packageID,
            version: secondVersion,
            expectedPackageHash: try secondManifest.packageHash(),
            state: .validated,
            reservedAt: timestamp,
            updatedAt: timestamp,
            validatedDescriptors: secondManifest.descriptors)

        #expect(throws: RendererMachineIndexStoreError.duplicateLogicalRenderer) {
            _ = try RendererMachineIndex(records: [firstRecord, secondRecord])
        }
    }

    @Test("consecutive activation supersedes the prior logical renderer version")
    func consecutiveActivationProjectsOnlyNewestVersionAndRetainsRollbackData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()

        let firstPackage = try fixture.validate()
        let first = try await store.activate(firstPackage, expectedGeneration: 0, clock: fixture.clock)
        let firstVersion = fixture.version

        let secondVersion = try fixture.rewrite(
            versionRaw: "1.0.1",
            contents: Data("<html>new renderer</html>".utf8))
        let secondPackage = try fixture.validate()
        let second = try await store.activate(
            secondPackage,
            expectedGeneration: first.generation,
            clock: fixture.clock)

        #expect(second.records.map(\.version) == [firstVersion, secondVersion])
        #expect(second.records.contains { $0.version == firstVersion && $0.state == .superseded })
        #expect(second.records.contains {
            $0.version == secondVersion && $0.state == .validated && $0.rollbackCandidate == firstVersion
        })
        #expect(second.availableDescriptorProjection.map(\.reference) == [secondPackage.manifest.descriptors[0].reference])
        #expect(FileManager.default.fileExists(atPath: fixture.layout.packageURL(
            packageID: fixture.packageID,
            version: firstVersion).path))
    }

    @Test func revalidationFailureCleansStagingAndDoesNotActivate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        try Data("changed after validation".utf8).write(to: package.stagedRoot.appendingPathComponent("index.html"))
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()

        await #expect(throws: RendererMachineIndexStoreError.activationFailed) {
            try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        }

        #expect(try await store.read().records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: package.stagedRoot.path) == false)
    }

    @Test func installedRootPassedToPublicActivationIsNeverDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        let activated = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)
        let installed = try RendererPackageValidator(packageRoot: fixture.layout.root, stagingRoot: fixture.layout.stagingRoot)
            .revalidateDirectory(root, expectedHash: package.packageHash)

        await #expect(throws: RendererMachineIndexStoreError.activationFailed) {
            try await store.activate(installed, expectedGeneration: activated.generation, clock: fixture.clock)
        }

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
        #expect(try await store.read().availableDescriptorProjection == fixture.manifest.descriptors)
    }

    @Test func existingIdenticalPackageVersionIsAnIdempotentNoOp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        let activated = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        let retry = try fixture.validate()
        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)

        let repeated = try await store.activate(retry, expectedGeneration: activated.generation, clock: fixture.clock)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: retry.stagedRoot.path) == false)
        #expect(repeated == activated)

        let staleRetry = try fixture.validate()
        await #expect(throws: RendererMachineIndexStoreError.staleGeneration) {
            try await store.activate(staleRetry, expectedGeneration: activated.generation + 1, clock: fixture.clock)
        }
        #expect(FileManager.default.fileExists(atPath: staleRetry.stagedRoot.path) == false)
    }

    @Test func existingConflictingPackageVersionFailsBeforeTheNoReplaceMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        let activated = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        try fixture.rewrite(contents: Data("different renderer payload".utf8))
        let conflicting = try fixture.validate()
        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)

        await #expect(throws: RendererMachineIndexStoreError.conflictingExpectedHash) {
            try await store.activate(conflicting, expectedGeneration: activated.generation, clock: fixture.clock)
        }

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: conflicting.stagedRoot.path) == false)
        #expect(try await store.read() == activated)
    }

    @Test func matchingHashForNonValidatedRecordFailsClosedAtExistingDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        let activated = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        let timestamp = try RFC3339Timestamp(validating: "2026-08-08T17:00:00+00:00")
        let quarantined = try RendererPackageInstallRecord(
            packageID: fixture.packageID,
            version: fixture.version,
            expectedPackageHash: package.packageHash,
            state: .quarantined,
            reservedAt: timestamp,
            updatedAt: timestamp)
        let quarantinedIndex = try await store.mutate(expectedGeneration: activated.generation) { records, _ in
            records = [quarantined]
        }
        let retry = try fixture.validate()

        await #expect(throws: RendererMachineIndexStoreError.packageRootAlreadyExists) {
            _ = try await store.activate(
                retry,
                expectedGeneration: quarantinedIndex.generation,
                clock: fixture.clock)
        }

        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
        #expect(try await store.read().records == [quarantined])
    }

    @Test func activationHashConflictRollsBackNewlyMovedPackage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        _ = try await store.activate(first, expectedGeneration: 0, clock: fixture.clock)
        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)
        _ = try await store.mutate(expectedGeneration: 1) { records, _ in records.removeAll() }
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.rewrite(contents: Data("replacement renderer".utf8))
        let replacement = try fixture.validate()

        await #expect(throws: RendererMachineIndexStoreError.conflictingExpectedHash) {
            try await store.activate(replacement, expectedGeneration: 2, clock: fixture.clock)
        }

        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        #expect((try await store.read()).records.isEmpty)
    }

    @Test func cancelledActivationCleansStagingWithoutCreatingARecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        let clock = fixture.clock
        _ = try await store.read()
        let task = Task { try await store.activate(package, expectedGeneration: 0, clock: clock) }
        task.cancel()

        await #expect(throws: RendererMachineIndexStoreError.activationCancelled) {
            _ = try await task.value
        }

        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)
        #expect(FileManager.default.fileExists(atPath: package.stagedRoot.path) == false)
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
        #expect(try await store.read().records.isEmpty)
    }

    @Test func coordinatorFailurePreservesCallerOwnedStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        _ = try await RendererMachineIndexStore(layout: fixture.layout).read()
        let coordinator = RendererPackageStoreCoordinator(
            layout: fixture.layout,
            processIdentity: RendererProcessIdentity(processID: 42, executableIdentity: "test", hostIdentity: "test-host", bootSessionIdentity: nil),
            tokenGenerator: InvalidCoordinatorToken()
        )
        let store = RendererMachineIndexStore(layout: fixture.layout, coordinator: coordinator)

        do {
            _ = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
            Issue.record("Expected coordinator acquisition to fail.")
        } catch {
            let failure = error as? RendererCoordinatorFailure
            #expect(failure == .invalidOwnerToken)
        }

        let destination = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)
        #expect(FileManager.default.fileExists(atPath: package.stagedRoot.path))
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(try await RendererMachineIndexStore(layout: fixture.layout).read().records.isEmpty)
    }

    @Test func cleanupFailureNeverActivatesARevalidationFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        try Data("changed after validation".utf8).write(to: package.stagedRoot.appendingPathComponent("index.html"))
        let store = RendererMachineIndexStore(layout: fixture.layout, activationCleaner: FailingCleaner())
        _ = try await store.read()

        await #expect(throws: RendererMachineIndexStoreError.activationCleanupFailed) {
            try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        }

        #expect(try await store.read().records.isEmpty)
    }

    @Test func finalPackageRootStaysContainedAndRejectsLinksOnRevalidation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        _ = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        let finalRoot = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)

        #expect(isRendererPackageStorePathContained(finalRoot, within: fixture.layout.packagesRoot))
        #expect(isRendererPackageStorePathContained(finalRoot.appendingPathComponent("../escape"), within: fixture.layout.packagesRoot) == false)
        #expect(symlink("index.html", finalRoot.appendingPathComponent("linked.html").path) == 0)
        #expect(throws: RendererPackageValidationError.self) {
            try RendererPackageValidator(packageRoot: fixture.layout.root, stagingRoot: fixture.layout.stagingRoot)
                .revalidateDirectory(finalRoot, expectedHash: package.packageHash)
        }
    }

    @Test func unavailableRecordsAreExcludedAndAvailableDescriptorsSortByReference() throws {
        let first = try Fixture(packageIDRaw: "org.example.projection-z")
        defer { first.remove() }
        let second = try Fixture(packageIDRaw: "org.example.projection-a")
        defer { second.remove() }
        let timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        let availableFirst = try RendererPackageInstallRecord(packageID: first.packageID, version: first.version, expectedPackageHash: try first.manifest.packageHash(), state: .validated, reservedAt: timestamp, updatedAt: timestamp, validatedDescriptors: first.manifest.descriptors)
        let unavailable = try RendererPackageInstallRecord(packageID: first.packageID, version: try RendererPackageVersion(validating: "2.0.0"), expectedPackageHash: try first.manifest.packageHash(), state: .quarantined, reservedAt: timestamp, updatedAt: timestamp)
        let availableSecond = try RendererPackageInstallRecord(packageID: second.packageID, version: second.version, expectedPackageHash: try second.manifest.packageHash(), state: .validated, reservedAt: timestamp, updatedAt: timestamp, validatedDescriptors: second.manifest.descriptors)
        let index = try RendererMachineIndex(records: [availableFirst, unavailable, availableSecond])

        #expect(index.availableDescriptorProjection == [second.manifest.descriptors[0], first.manifest.descriptors[0]])
        #expect(try RendererMachineIndex(records: [availableFirst, availableSecond], safeModeIsEnabled: true).availableDescriptorProjection.isEmpty)
    }

    @Test func installRecordRejectsDuplicateValidatedDescriptorReferences() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        let descriptor = fixture.manifest.descriptors[0]

        #expect(throws: RendererValidationError.self) {
            _ = try RendererPackageInstallRecord(
                packageID: fixture.packageID,
                version: fixture.version,
                expectedPackageHash: try fixture.manifest.packageHash(),
                state: .validated,
                reservedAt: timestamp,
                updatedAt: timestamp,
                validatedDescriptors: [descriptor, descriptor]
            )
        }
    }

    @Test func installRecordRejectsValidatedDescriptorForAnotherPackage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = try Fixture(packageIDRaw: "org.example.other-package")
        defer { other.remove() }
        let timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")

        #expect(throws: RendererValidationError.self) {
            _ = try RendererPackageInstallRecord(
                packageID: fixture.packageID,
                version: fixture.version,
                expectedPackageHash: try fixture.manifest.packageHash(),
                state: .validated,
                reservedAt: timestamp,
                updatedAt: timestamp,
                validatedDescriptors: other.manifest.descriptors
            )
        }
    }

    @Test func installRecordRejectsDescriptorsThatDoNotMatchItsState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")

        #expect(throws: RendererValidationError.self) {
            _ = try RendererPackageInstallRecord(
                packageID: fixture.packageID,
                version: fixture.version,
                expectedPackageHash: try fixture.manifest.packageHash(),
                state: .validated,
                reservedAt: timestamp,
                updatedAt: timestamp
            )
        }
        #expect(throws: RendererValidationError.self) {
            _ = try RendererPackageInstallRecord(
                packageID: fixture.packageID,
                version: fixture.version,
                expectedPackageHash: try fixture.manifest.packageHash(),
                state: .quarantined,
                reservedAt: timestamp,
                updatedAt: timestamp,
                validatedDescriptors: fixture.manifest.descriptors
            )
        }
    }

    @Test func priorIndexSchemaIsRejectedBeforeDescriptorProjection() throws {
        let legacy = Data("""
        {"schemaVersion":1,"generation":0,"records":[],"safeModeIsEnabled":false}
        """.utf8)

        #expect(RendererMachineIndex.currentSchemaVersion == 4)
        #expect(throws: RendererMachineIndexStoreError.unsupportedSchemaVersion) {
            _ = try JSONDecoder().decode(RendererMachineIndex.self, from: legacy)
        }
    }

    @Test("schema v3 duplicate active versions migrate to one active renderer")
    func schemaV3DuplicateActiveVersionsMigrateToNewestVersion() throws {
        let packageID = try RendererPackageID(validating: "org.example.legacy")
        let firstVersion = try RendererPackageVersion(validating: "1.0.0")
        let secondVersion = try RendererPackageVersion(validating: "1.0.1")
        let timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
        let records = try [firstVersion, secondVersion].map { version in
            let manifest = try Fixture.makeManifest(
                packageID: packageID,
                version: version,
                contents: Data(version.rawValue.utf8))
            return try RendererPackageInstallRecord(
                packageID: packageID,
                version: version,
                expectedPackageHash: try manifest.packageHash(),
                state: .validated,
                reservedAt: timestamp,
                updatedAt: timestamp,
                validatedDescriptors: manifest.descriptors)
        }
        let legacy = LegacyRendererMachineIndex(
            schemaVersion: 3,
            generation: 7,
            records: records,
            safeModeIsEnabled: false,
            installedRendererFailures: [])

        let migrated = try JSONDecoder().decode(
            RendererMachineIndex.self,
            from: JSONEncoder().encode(legacy))

        #expect(RendererMachineIndex.currentSchemaVersion == 4)
        #expect(migrated.generation == 7)
        #expect(migrated.records.map(\.state) == [.superseded, .validated])
        #expect(migrated.records.last?.rollbackCandidate == firstVersion)
        #expect(migrated.availableDescriptorProjection.map(\.reference.version) == [secondVersion])
    }

    private final class Fixture {
        let root: URL
        let layout: RendererPackageStoreLayout
        let source: URL
        let packageID: RendererPackageID
        let version: RendererPackageVersion
        private(set) var manifest: RendererManifest
        let clock: FixedClock

        init(packageIDRaw: String = "org.example.activation") throws {
            clock = try FixedClock()
            root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-package-activation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
            source = root.appendingPathComponent("candidate", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            packageID = try RendererPackageID(validating: packageIDRaw)
            version = try RendererPackageVersion(validating: "1.0.0")
            manifest = try Self.makeManifest(packageID: packageID, version: version, contents: Data("<html>activated renderer</html>".utf8))
            try Data("<html>activated renderer</html>".utf8).write(to: source.appendingPathComponent("index.html"))
            try manifest.canonicalJSON().write(to: source.appendingPathComponent("manifest.json"))
        }

        func rewrite(contents: Data) throws {
            try contents.write(to: source.appendingPathComponent("index.html"))
            manifest = try Self.makeManifest(packageID: packageID, version: version, contents: contents)
            try manifest.canonicalJSON().write(to: source.appendingPathComponent("manifest.json"))
        }

        func rewrite(versionRaw: String, contents: Data) throws -> RendererPackageVersion {
            let version = try RendererPackageVersion(validating: versionRaw)
            try contents.write(to: source.appendingPathComponent("index.html"))
            manifest = try Self.makeManifest(packageID: packageID, version: version, contents: contents)
            try manifest.canonicalJSON().write(to: source.appendingPathComponent("manifest.json"))
            return version
        }

        static func makeManifest(packageID: RendererPackageID, version: RendererPackageVersion, contents: Data) throws -> RendererManifest {
            let asset = RendererAsset(path: try RendererRelativePath(validating: "index.html"), digest: RendererSHA256.digest(contents))
            let descriptor = try RendererDescriptor(
                reference: .init(packageID: packageID, version: version, registrationID: try RendererRegistrationID(validating: "viewer")),
                displayName: "Activation fixture",
                implementation: .webPackage(.init(path: asset.path)),
                matchers: [.artifactKind(.source)], presentations: [.web], approvedAssets: [asset], capabilities: [.inputRead],
                sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1), linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
            return try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [asset])
        }

        func validate() throws -> ValidatedRendererPackage {
            try RendererPackageValidator(packageRoot: layout.root, stagingRoot: layout.stagingRoot).validate(directory: source)
        }

        func remove() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
    }
}

private struct LegacyRendererMachineIndex: Encodable {
    let schemaVersion: Int
    let generation: UInt64
    let records: [RendererPackageInstallRecord]
    let safeModeIsEnabled: Bool
    let installedRendererFailures: [RendererInstalledRendererFailure]
}

private struct FixedClock: RendererEventClock {
    let timestamp: RFC3339Timestamp

    init() throws {
        timestamp = try RFC3339Timestamp(validating: "2026-08-05T12:00:00+00:00")
    }

    func now() -> RFC3339Timestamp { timestamp }
}

private struct FailingCleaner: RendererPackageActivationCleaning {
    func removeRecursively(_: URL) throws { throw CleanupFailure() }

    private struct CleanupFailure: Error {}
}

private struct InvalidCoordinatorToken: RendererCoordinatorOwnerTokenGenerating {
    func nextOwnerToken() -> String { "invalid" }
}
