import Darwin
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

    @Test func existingDestinationIsAnExplicitConflictAndCleansOnlyStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        _ = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        let retry = try fixture.validate()
        let root = fixture.layout.packageURL(packageID: fixture.packageID, version: fixture.version)

        await #expect(throws: RendererMachineIndexStoreError.packageRootAlreadyExists) {
            try await store.activate(retry, expectedGeneration: 1, clock: fixture.clock)
        }

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath: retry.stagedRoot.path) == false)
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

    @Test func priorIndexSchemaIsRejectedBeforeDescriptorProjection() throws {
        let legacy = Data("""
        {"schemaVersion":1,"generation":0,"records":[],"safeModeIsEnabled":false}
        """.utf8)

        #expect(RendererMachineIndex.currentSchemaVersion == 2)
        #expect(throws: RendererMachineIndexStoreError.unsupportedSchemaVersion) {
            _ = try JSONDecoder().decode(RendererMachineIndex.self, from: legacy)
        }
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

        private static func makeManifest(packageID: RendererPackageID, version: RendererPackageVersion, contents: Data) throws -> RendererManifest {
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
