import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// Fail-closed fence-claim admission at the validator and activation
/// boundaries: reserved built-in aliases never install, a package cannot take
/// another installed package's alias, and removal frees the alias.
@Suite("Package fence claim admission", .serialized, .timeLimit(.minutes(1)))
struct PackageFenceClaimAdmissionTests {
    private static let clock = PackageFenceFixedClock(timestamp: "2026-08-31T12:00:00+00:00")

    private static func d2Alias() throws -> RendererFenceAlias {
        try RendererFenceAlias(validating: "d2")
    }

    private static func mermaidAlias() throws -> RendererFenceAlias {
        try RendererFenceAlias(validating: "mermaid")
    }

    private final class Fixture {
        let root: URL
        let layout: RendererPackageStoreLayout
        let source: URL
        let packageID: RendererPackageID
        private(set) var version: RendererPackageVersion

        init(
            packageIDRaw: String,
            claims: [RendererFenceClaim]
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("fence-admission-\(UUID().uuidString)", isDirectory: true)
            layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
            source = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            packageID = try RendererPackageID(validating: packageIDRaw)
            version = try RendererPackageVersion(validating: "1.0.0")
            try Self.writePackage(to: source, packageID: packageID, version: version, claims: claims)
        }

        func rewrite(versionRaw: String, claims: [RendererFenceClaim]) throws -> RendererPackageVersion {
            version = try RendererPackageVersion(validating: versionRaw)
            try Self.writePackage(to: source, packageID: packageID, version: version, claims: claims)
            return version
        }

        func validate(reservedFenceAliases: Set<RendererFenceAlias> = []) throws -> ValidatedRendererPackage {
            try RendererPackageValidator(
                packageRoot: layout.root,
                stagingRoot: layout.stagingRoot,
                reservedFenceAliases: reservedFenceAliases)
                .validate(directory: source)
        }

        private static func writePackage(
            to source: URL,
            packageID: RendererPackageID,
            version: RendererPackageVersion,
            claims: [RendererFenceClaim]
        ) throws {
            let asset = RendererAsset(
                path: try RendererRelativePath(validating: "index.html"),
                digest: RendererSHA256.digest(Data("<html>fixture</html>".utf8)))
            let descriptor = try RendererDescriptor(
                reference: .init(
                    packageID: packageID,
                    version: version,
                    registrationID: try RendererRegistrationID(validating: "viewer")),
                displayName: "Fence Fixture",
                implementation: .webPackage(.init(path: asset.path)),
                matchers: [.artifactKind(.source)],
                presentations: [.web],
                supportedEmbeddingRoles: [.disclosureRow],
                hasExplicitEmbeddingRoles: true,
                fenceClaims: claims,
                approvedAssets: [asset],
                capabilities: [.inputRead],
                sizeLimits: try .init(maximumInputByteCount: 1_024, maximumDecodedByteCount: 2_048),
                linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: try .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
                priority: 0)
            let manifest = try RendererManifest(
                revision: RendererManifestRevision.current,
                packageID: packageID,
                version: version,
                descriptors: [descriptor],
                assets: [asset])
            try Data("<html>fixture</html>".utf8).write(to: source.appendingPathComponent("index.html"))
            try manifest.canonicalJSON().write(to: source.appendingPathComponent("manifest.json"))
        }

        func remove() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
    }

    @Test("a validator with the built-in reserved set rejects a reserved claim")
    func validatorRejectsReservedAlias() throws {
        let fixture = try Fixture(
            packageIDRaw: "org.example.squatter",
            claims: [RendererFenceClaim(
                alias: Self.mermaidAlias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { fixture.remove() }

        let mermaid = try Self.mermaidAlias()
        #expect(throws: RendererPackageValidationError.reservedFenceAlias(mermaid)) {
            _ = try fixture.validate(
                reservedFenceAliases: [mermaid, Self.d2Alias()])
        }
        // Without the reserved set the same package validates: the guard is
        // injected authority, not a hidden host table at this layer.
        _ = try fixture.validate()
    }

    @Test("activation rejects a reserved alias even without validator injection")
    func activationRejectsReservedAlias() async throws {
        let fixture = try Fixture(
            packageIDRaw: "org.example.squatter",
            claims: [RendererFenceClaim(
                alias: Self.mermaidAlias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { fixture.remove() }
        let package = try fixture.validate()
        let reserved = try Self.mermaidAlias()
        let store = RendererMachineIndexStore(
            layout: fixture.layout,
            reservedFenceAliases: [reserved])
        _ = try await store.read()

        await #expect(throws: RendererMachineIndexStoreError.reservedFenceAlias(reserved)) {
            _ = try await store.activate(package, expectedGeneration: 0, clock: Self.clock)
        }
        #expect(try await store.read().records.isEmpty)
    }

    @Test("activation rejects an alias another installed package claims")
    func activationRejectsInstalledAliasCollision() async throws {
        let first = try Fixture(
            packageIDRaw: "org.example.first",
            claims: [RendererFenceClaim(
                alias: Self.d2Alias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { first.remove() }
        let second = try Fixture(
            packageIDRaw: "org.example.second",
            claims: [RendererFenceClaim(
                alias: Self.d2Alias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { second.remove() }

        // Both share one machine layout so the second install sees the first.
        let secondLayoutPackage = try RendererPackageValidator(
            packageRoot: first.layout.root,
            stagingRoot: first.layout.stagingRoot)
            .validate(directory: second.source)

        let store = RendererMachineIndexStore(layout: first.layout)
        _ = try await store.read()
        let firstPackage = try first.validate()
        _ = try await store.activate(firstPackage, expectedGeneration: 0, clock: Self.clock)

        let d2 = try Self.d2Alias()
        await #expect(throws: RendererMachineIndexStoreError.conflictingFenceAlias(d2)) {
            _ = try await store.activate(secondLayoutPackage, expectedGeneration: 1, clock: Self.clock)
        }
    }

    @Test("a newer version of the same package keeps its own alias")
    func samePackageUpgradeKeepsAlias() async throws {
        let fixture = try Fixture(
            packageIDRaw: "org.example.d2owner",
            claims: [RendererFenceClaim(
                alias: Self.d2Alias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { fixture.remove() }
        let d2 = try Self.d2Alias()
        let store = RendererMachineIndexStore(layout: fixture.layout)
        _ = try await store.read()
        let first = try fixture.validate()
        let activated = try await store.activate(first, expectedGeneration: 0, clock: Self.clock)

        _ = try fixture.rewrite(
            versionRaw: "1.0.1",
            claims: [RendererFenceClaim(
                alias: d2,
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        let upgraded = try fixture.validate()
        let next = try await store.activate(upgraded, expectedGeneration: activated.generation, clock: Self.clock)

        #expect(next.availableDescriptorProjection.count == 1)
        #expect(next.availableDescriptorProjection.first?.fenceClaims.map(\.alias) == [d2])
    }

    @Test("removing the claimant frees the alias for another package")
    func removalFreesAlias() async throws {
        let first = try Fixture(
            packageIDRaw: "org.example.first",
            claims: [RendererFenceClaim(
                alias: Self.d2Alias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { first.remove() }
        let store = RendererMachineIndexStore(layout: first.layout)
        _ = try await store.read()
        let package = try first.validate()
        let activated = try await store.activate(package, expectedGeneration: 0, clock: Self.clock)

        let removed = try await store.remove(
            packageID: first.packageID,
            version: first.version,
            expectedGeneration: activated.generation,
            clock: Self.clock)
        // Removal keeps a redacted `.removed` record but frees the alias: the
        // availability projection no longer contains the claimant.
        #expect(removed.availableDescriptorProjection.isEmpty)

        // A different package may now claim the same alias.
        let second = try Fixture(
            packageIDRaw: "org.example.second",
            claims: [RendererFenceClaim(
                alias: Self.d2Alias(),
                inlineMIMEType: try RendererMIMEType(validating: "text/plain"))])
        defer { second.remove() }
        let secondPackage = try RendererPackageValidator(
            packageRoot: first.layout.root,
            stagingRoot: first.layout.stagingRoot)
            .validate(directory: second.source)
        let installed = try await store.activate(
            secondPackage,
            expectedGeneration: removed.generation,
            clock: Self.clock)
        #expect(installed.availableDescriptorProjection.first?.hasFenceClaims == true)
    }
}

/// Fixed clock matching the activation fixtures' deterministic timestamps.
private struct PackageFenceFixedClock: RendererEventClock {
    let timestamp: String
    func now() -> RFC3339Timestamp {
        (try? RFC3339Timestamp(validating: timestamp))
            ?? RFC3339Timestamp(date: Date(timeIntervalSince1970: 0))
    }
}
