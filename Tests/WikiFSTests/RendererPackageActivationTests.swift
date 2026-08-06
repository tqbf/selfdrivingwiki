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

    @Test func safeModeAndUnavailableRecordsAreExcludedFromDeterministicProjection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let package = try fixture.validate()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        let activated = try await store.activate(package, expectedGeneration: 0, clock: fixture.clock)
        #expect(activated.availableDescriptorProjection == fixture.manifest.descriptors)

        let safe = try await store.mutate(expectedGeneration: activated.generation) { _, safeMode in safeMode = true }

        #expect(safe.availableDescriptorProjection.isEmpty)
    }

    private final class Fixture {
        let root: URL
        let layout: RendererPackageStoreLayout
        let source: URL
        let packageID: RendererPackageID
        let version: RendererPackageVersion
        let manifest: RendererManifest
        let clock: FixedClock

        init() throws {
            clock = try FixedClock()
            root = FileManager.default.temporaryDirectory.appendingPathComponent("renderer-package-activation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
            source = root.appendingPathComponent("candidate", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let bytes = Data("<html>activated renderer</html>".utf8)
            try bytes.write(to: source.appendingPathComponent("index.html"))
            packageID = try RendererPackageID(validating: "org.example.activation")
            version = try RendererPackageVersion(validating: "1.0.0")
            let asset = RendererAsset(path: try RendererRelativePath(validating: "index.html"), digest: RendererSHA256.digest(bytes))
            let descriptor = try RendererDescriptor(
                reference: .init(packageID: packageID, version: version, registrationID: try RendererRegistrationID(validating: "viewer")),
                displayName: "Activation fixture",
                implementation: .webPackage(.init(path: asset.path)),
                matchers: [.artifactKind(.source)], presentations: [.web], approvedAssets: [asset], capabilities: [.inputRead],
                sizeLimits: try .init(maximumInputByteCount: 1, maximumDecodedByteCount: 1), linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1), priority: 0)
            manifest = try RendererManifest(revision: 1, packageID: packageID, version: version, descriptors: [descriptor], assets: [asset])
            try manifest.canonicalJSON().write(to: source.appendingPathComponent("manifest.json"))
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
