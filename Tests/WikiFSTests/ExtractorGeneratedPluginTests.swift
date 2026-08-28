import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSExtractorStore
@testable import WikiFSCore
import WikiFSTypes

@Suite("Extraction backend registry batches", .serialized, .timeLimit(.minutes(1)))
struct ExtractionBackendRegistryBatchTests {
    @Test func batchCommitsAtomicallyAndDisposeRemovesExactlyItsOwnEntries() async throws {
        let registry = ExtractionBackendRegistry()
        _ = try await registry.register(makeBuiltInBackend(id: "legacy"))

        let entries = try makeBatchEntries(
            version: "1.0.0",
            digest: String(repeating: "a", count: 64))
        let batch = try await registry.registerBatch(entries)

        #expect(await registry.allKeys().count == 3)
        #expect(await registry.keys().count == 1)

        await batch.dispose()
        let remaining = await registry.allKeys()
        #expect(remaining.count == 1)
        guard case .builtIn = remaining.first else {
            Issue.record("Only the built-in entry should remain")
            return
        }

        // A second disposal is a harmless no-op.
        await batch.dispose()
        #expect(await registry.allKeys().count == 1)
    }

    @Test func collisionCommitsNothing() async throws {
        let registry = ExtractionBackendRegistry()
        let first = try makeBatchEntries(version: "1.0.0", digest: String(repeating: "b", count: 64))
        _ = try await registry.registerBatch(first)

        // Rebuilding the same keys collides; a second distinct key must not leak.
        var conflicting = try makeBatchEntries(version: "1.0.0", digest: String(repeating: "b", count: 64))
        conflicting.append(contentsOf: try makeBatchEntries(version: "9.9.9", digest: String(repeating: "c", count: 64)))
        do {
            _ = try await registry.registerBatch(conflicting)
            Issue.record("Expected collision")
        } catch ExtractionBackendRegistryError.batchCollision(let keys) {
            #expect(keys.count == 2)
        }
        #expect(await registry.allKeys().count == 2)
    }

    @Test func staleBatchDisposerCannotRemoveNewerRegistration() async throws {
        let registry = ExtractionBackendRegistry()
        let keys = try exactKeys(version: "1.0.0", digestHex: String(repeating: "d", count: 64))

        let first = try await registry.registerBatch([
            ExtractionBatchEntry(key: keys[0], backend: makeStubBackend()),
        ])
        await first.dispose()

        // A newer batch reuses the same exact key under a different token.
        let second = try await registry.registerBatch([
            ExtractionBatchEntry(key: keys[0], backend: makeStubBackend()),
        ])
        #expect(await registry.resolve(keys[0]) != nil)

        // The stale disposer must be a no-op against the newer token.
        await first.dispose()
        #expect(await registry.resolve(keys[0]) != nil)

        await second.dispose()
        #expect(await registry.resolve(keys[0]) == nil)
    }

    @Test func logicalResolutionRanksSemverThenIdentity() async throws {
        let registry = ExtractionBackendRegistry()
        let lowReference = try reference(
            packageID: "org.example.rank",
            version: "1.0.0",
            digestHex: String(repeating: "e", count: 64))
        let highSameVersion = try reference(
            packageID: "org.example.rank",
            version: "2.0.0",
            digestHex: String(repeating: "f", count: 64))
        let highOtherDigest = try reference(
            packageID: "org.example.rank",
            version: "2.0.0",
            digestHex: String(repeating: "0", count: 63) + "1")

        for candidate in [lowReference, highOtherDigest, highSameVersion] {
            _ = try await registry.registerBatch([
                ExtractionBatchEntry(
                    key: .installed(kind: .pdf, reference: candidate),
                    backend: makeStubBackend()),
            ])
        }

        let logical = LogicalExtractorReference(
            packageID: lowReference.revision.packageID,
            registrationID: lowReference.registrationID)
        let best = await registry.resolveInstalled(logical, kind: .pdf)
        #expect(best?.key == .installed(kind: .pdf, reference: highSameVersion))
        #expect(best?.key != .installed(kind: .pdf, reference: highOtherDigest))
    }

    @Test func kindFilteringKeepsNamespacesSeparate() async throws {
        let registry = ExtractionBackendRegistry()
        let reference = try reference(
            packageID: "org.example.kinds",
            version: "1.0.0",
            digestHex: String(repeating: "9", count: 64))
        _ = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installed(kind: .html, reference: reference),
                backend: makeStubBackend()),
        ])

        let logical = LogicalExtractorReference(
            packageID: reference.revision.packageID,
            registrationID: reference.registrationID)
        #expect(await registry.resolveInstalled(logical, kind: .pdf) == nil)
        #expect(await registry.resolveInstalled(logical, kind: .html) != nil)
    }

    // MARK: - Route presentation snapshots

    @Test func presentationSnapshotsCarryManifestMetadataAndDropWithDisposal() async throws {
        let registry = ExtractionBackendRegistry()
        let lowReference = try reference(
            packageID: "org.example.route",
            version: "1.0.0",
            digestHex: String(repeating: "1", count: 64))
        let highReference = try reference(
            packageID: "org.example.route",
            version: "2.0.0",
            digestHex: String(repeating: "2", count: 64))
        let pdfMIME = try ExtractorMIMEType(validating: "application/pdf")
        let pdfExtension = try #require(ExtractorFileExtension(rawValue: "pdf"))
        let presentation = ExtractorRegistrationPresentation(
            displayName: "Main",
            packageName: "Route Package",
            kinds: [.pdf, .html],
            mimeTypes: [pdfMIME],
            filenameExtensions: [pdfExtension])
        let batch = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installed(kind: .pdf, reference: lowReference),
                backend: makeStubBackend(),
                presentation: presentation),
            ExtractionBatchEntry(
                key: .installed(kind: .pdf, reference: highReference),
                backend: makeStubBackend(),
                presentation: presentation),
            ExtractionBatchEntry(
                key: .installed(kind: .html, reference: highReference),
                backend: makeStubBackend(),
                presentation: presentation),
            ExtractionBatchEntry(
                key: .builtIn(ExtractionBackendKey(kind: .pdf, backendID: "legacy")),
                backend: makeStubBackend()),
        ])

        var snapshots = await registry.installedRegistrationSnapshots()
        // One snapshot per exact registration reference — the same registration
        // registered in the PDF and HTML namespaces collapses onto its single
        // reference. Built-ins never appear.
        #expect(snapshots.count == 2)
        #expect(snapshots.map(\.reference) == [lowReference, highReference])
        #expect(snapshots.allSatisfy { $0.displayName == "Main" && $0.packageName == "Route Package" })
        #expect(snapshots.allSatisfy { $0.kinds == [.pdf, .html] })
        #expect(snapshots.allSatisfy { $0.mimeTypes == [pdfMIME] })
        #expect(snapshots.allSatisfy { $0.filenameExtensions == [pdfExtension] })

        await batch.dispose()
        snapshots = await registry.installedRegistrationSnapshots()
        #expect(snapshots.isEmpty)
    }

    // MARK: - Helpers

    private func makeBuiltInBackend(id: String) -> RegisteredExtractionBackend {
        RegisteredExtractionBackend(key: ExtractionBackendKey(kind: .pdf, backendID: id)) {
            .pdf(ExtractionPreparation(
                extractor: StubMarkdownExtractor(),
                backend: .localPdf2md,
                modelVersion: nil))
        }
    }

    private func makeStubBackend() -> RegisteredExtractionBackend {
        RegisteredExtractionBackend(key: ExtractionBackendKey(kind: .pdf, backendID: "stub")) {
            .pdf(ExtractionPreparation(
                extractor: StubMarkdownExtractor(),
                backend: .localPdf2md,
                modelVersion: nil))
        }
    }

    private func reference(
        packageID: String,
        version: String,
        digestHex: String
    ) throws -> ExtractorReference {
        ExtractorReference(
            revision: ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: packageID),
                version: try ExtractorPackageVersion(validating: version),
                digest: try ExtractorPackageDigest(hex: digestHex)),
            registrationID: try ExtractorRegistrationID(validating: "pdf"))
    }

    private func exactKeys(
        version: String,
        digestHex: String
    ) throws -> [ExtractionAdapterKey] {
        let base = try reference(
            packageID: "org.example.tokens",
            version: version,
            digestHex: digestHex)
        return [.installed(kind: .pdf, reference: base)]
    }

    private func makeBatchEntries(
        version: String,
        digest: String
    ) throws -> [ExtractionBatchEntry] {
        let pdf = try reference(packageID: "org.example.batch", version: version, digestHex: digest)
        let html = ExtractorReference(
            revision: pdf.revision,
            registrationID: try ExtractorRegistrationID(validating: "html"))
        return [
            ExtractionBatchEntry(
                key: .installed(kind: .pdf, reference: pdf),
                backend: makeStubBackend()),
            ExtractionBatchEntry(
                key: .installed(kind: .html, reference: html),
                backend: RegisteredExtractionBackend(
                    key: ExtractionBackendKey(kind: .html, backendID: "stub-html")) {
                        ExtractionBackendAdapter.html(StubHTMLExtractor())
                    }),
        ]
    }
}

struct StubMarkdownExtractor: MarkdownExtractor {
    var displayName: String { "stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

struct StubHTMLExtractor: HtmlMarkdownExtractor {
    func extract(html: String) async -> HtmlExtractionResult? { nil }
}

@Suite("Generated extractor plugin definitions", .serialized, .timeLimit(.minutes(3)))
struct ExtractorGeneratedPluginTests {
    @Test func definitionIdentityIsDeterministicAndPrefixed() throws {
        let manifest = try GeneratedPluginFixtures.manifest()
        let revision = ExtractorPackageRevisionID(
            packageID: manifest.packageID,
            version: manifest.version,
            digest: try manifest.packageDigest())

        let first = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
            revision: revision,
            manifest: manifest)
        let second = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
            revision: revision,
            manifest: manifest)

        #expect(first.plugin.id.rawValue.hasPrefix("dynamic:extractor-package/"))
        #expect(first.plugin.id == second.plugin.id)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.plugin.hasConfigSchema == false)
        #expect(first.declaredWorkCount == 1)
        #expect(first.plugin.dependencies.count == 6)
    }

    @Test func fingerprintChangesWhenRegistrationsChange() throws {
        let plain = try GeneratedPluginFixtures.manifest()
        var widened = plain
        widened = try Self.widen(manifest: plain)
        let revisionA = ExtractorPackageRevisionID(
            packageID: plain.packageID,
            version: plain.version,
            digest: try plain.packageDigest())
        let revisionB = ExtractorPackageRevisionID(
            packageID: widened.packageID,
            version: widened.version,
            digest: try widened.packageDigest())

        let fingerprintA = try ExtractorPackagePluginDefinitionFactory.fingerprint(
            for: plain,
            revision: revisionA)
        let fingerprintB = try ExtractorPackagePluginDefinitionFactory.fingerprint(
            for: widened,
            revision: revisionB)
        #expect(fingerprintA != fingerprintB)

        let idA = ExtractorPackagePluginDefinitionFactory.pluginID(for: revisionA)
        let idB = ExtractorPackagePluginDefinitionFactory.pluginID(for: revisionB)
        #expect(idA != idB)
    }

    private static func widen(manifest: ExtractorManifest) throws -> ExtractorManifest {
        try ExtractorManifest(
            manifestRevision: manifest.manifestRevision,
            packageID: manifest.packageID,
            version: ExtractorPackageVersion(validating: "1.0.1"),
            displayName: manifest.displayName,
            protocolRevision: manifest.protocolRevision,
            entryPoint: manifest.entryPoint,
            launch: manifest.launch,
            registrations: manifest.registrations,
            capabilities: manifest.capabilities,
            files: manifest.files.map {
                ExtractorPackageFile(path: $0.path, digest: $0.digest)
            },
            limits: manifest.limits)
    }

    @Test func generatedPluginActivatesRegistersAndStopsQuiescently() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }
        try await environment.supplyAll()

        let host = DynamicPluginHost(context: environment.context)
        let trusted = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
            revision: environment.revision,
            manifest: environment.manifest)
        _ = try await host.define(trusted)

        let outcome = try await host.run(trusted.id)
        guard case .active = outcome else {
            Issue.record("Expected active outcome, got \(outcome)")
            return
        }
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .active)
        #expect(inspection.currentComponentStateHistory.last == .active)

        let matches = await environment.registry.installedMatches(kind: .pdf)
        #expect(matches.count == 1)
        let htmlMatches = await environment.registry.installedMatches(kind: .html)
        #expect(htmlMatches.count == 1)

        // Stop consumes the cleanup effect exactly once and drains both
        // namespace registrations.
        await host.stop(trusted.id)
        #expect(await environment.registry.installedMatches(kind: .pdf).isEmpty)
        #expect(await environment.registry.installedMatches(kind: .html).isEmpty)
        let postStop = try #require(await host.inspect(trusted.id))
        #expect(postStop.lifecycle == .stopped)
    }

    @Test func waitingRunActivatesWhenHostServicesAppear() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }
        // Deliberately no supplies: every declared dependency is missing.

        let host = DynamicPluginHost(context: environment.context)
        let trusted = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
            revision: environment.revision,
            manifest: environment.manifest)
        _ = try await host.define(trusted)

        let waiting = try await host.run(trusted.id)
        guard case .waiting(_, _, let missing) = waiting else {
            Issue.record("Expected waiting outcome, got \(waiting)")
            return
        }
        #expect(missing.count == 6)

        try await environment.supplyAll()
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .active)
        #expect(inspection.retainedRuns.count == 1)

        #expect(await environment.registry.installedMatches(kind: .pdf).count == 1)
    }

    @Test func failedCatalogRevalidationLeavesRegistryUntouched() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }
        try await environment.supplyAll()

        let foreignManifest = try GeneratedPluginFixtures.uninstalledManifest()
        let foreignRevision = ExtractorPackageRevisionID(
            packageID: foreignManifest.packageID,
            version: foreignManifest.version,
            digest: try foreignManifest.packageDigest())
        let trusted = try ExtractorPackagePluginDefinitionFactory.trustedDefinition(
            revision: foreignRevision,
            manifest: foreignManifest)

        let host = DynamicPluginHost(context: environment.context)
        _ = try await host.define(trusted)
        let outcome = try await host.run(trusted.id)
        guard case .failed = outcome else {
            Issue.record("Expected failed outcome, got \(outcome)")
            return
        }
        let inspection = try #require(await host.inspect(trusted.id))
        #expect(inspection.lifecycle == .failed)
        #expect(await environment.registry.allKeys().isEmpty)
    }
}

enum GeneratedPluginFixtures {
    /// Manifest builder shared by identity-only checks (no installation).
    static func manifest() throws -> ExtractorManifest {
        try buildManifest(
            packageID: "org.example.generated",
            files: [ExtractorPackageFile(
                path: ExtractorRelativePath(validating: "bin/fixture"),
                digest: ExtractorSHA256.digest(Data()))])
    }

    static func uninstalledManifest() throws -> ExtractorManifest {
        try buildManifest(
            packageID: "org.example.foreign-generated",
            files: [ExtractorPackageFile(
                path: ExtractorRelativePath(validating: "bin/fixture"),
                digest: ExtractorSHA256.digest(Data()))])
    }

    static func buildManifest(
        packageID: String,
        files: [ExtractorPackageFile]
    ) throws -> ExtractorManifest {
        var registrations: [ExtractorRegistration] = [
            try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "pdf"),
                displayName: "PDF",
                kinds: [.pdf],
                mimeTypes: [ExtractorMIMEType(validating: "application/pdf")]),
            try ExtractorRegistration(
                id: ExtractorRegistrationID(validating: "html"),
                displayName: "HTML",
                kinds: [.html],
                mimeTypes: [ExtractorMIMEType(validating: "text/html")]),
        ]
        registrations.sort()
        return try ExtractorManifest(
            manifestRevision: .v1,
            packageID: ExtractorPackageID(validating: packageID),
            version: ExtractorPackageVersion(validating: "1.0.0"),
            displayName: "Generated Fixture",
            protocolRevision: .v1,
            entryPoint: ExtractorRelativePath(validating: "bin/fixture"),
            launch: .direct,
            registrations: registrations,
            capabilities: [],
            files: files,
            limits: ExtractorOperationLimits(
                maximumInputByteCount: 65_536,
                maximumMarkdownOutputByteCount: 65_536,
                maximumDurationMilliseconds: 10_000,
                maximumProgressEventCount: 8))
    }

    /// Installs the managed fixture as a real catalog revision inside an
    /// isolated `.test` App Group root and owns the shared CordisContext.
    final class InstalledEnvironment: @unchecked Sendable {
        enum EnvironmentError: Error {
            case installationFailed
            case missingFixtureExecutable
        }

        let root: URL
        let context: CordisContext
        let registry: ExtractionBackendRegistry
        let layout: ExtractorPackageStoreLayout
        let revision: ExtractorPackageRevisionID
        let manifest: ExtractorManifest

        /// The validated source directory the fixture was imported from. It
        /// stays on disk so tests can re-import the exact same revision.
        var sourcePackageRoot: URL {
            root.appendingPathComponent("source-package", isDirectory: true)
        }

        static func install() async throws -> InstalledEnvironment {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("generated-plugin-\(UUID().uuidString)", isDirectory: true)
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: root,
                processRole: .test)

            let sourceBytes = try Data(contentsOf: try findFixtureExecutable())
            let entryPath = try ExtractorRelativePath(validating: "bin/fixture")
            let packageRoot = root.appendingPathComponent("source-package", isDirectory: true)
            let entryURL = packageRoot.appendingPathComponent(entryPath.rawValue)
            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try sourceBytes.write(to: entryURL)
            guard chmod(entryURL.path, 0o500) == 0 else { throw POSIXError(.EIO) }

            let manifest = try buildManifest(
                packageID: "org.example.generated",
                files: [ExtractorPackageFile(
                    path: entryPath,
                    digest: ExtractorSHA256.digest(sourceBytes))])
            try JSONEncoder().encode(manifest).write(
                to: packageRoot.appendingPathComponent("manifest.json"))

            let writer = try ExtractorPackageCatalogWriter.testing(layout: layout)
            let installed = try await writer.importDirectory(
                packageRoot,
                installedAt: RFC3339Timestamp(date: Date()))
            guard let record = installed.records.first(where: {
                $0.revision.packageID.rawValue == "org.example.generated"
            }) else {
                throw EnvironmentError.installationFailed
            }

            return InstalledEnvironment(
                root: root,
                layout: layout,
                revision: record.revision,
                manifest: manifest)
        }

        private init(
            root: URL,
            layout: ExtractorPackageStoreLayout,
            revision: ExtractorPackageRevisionID,
            manifest: ExtractorManifest
        ) {
            self.root = root
            self.layout = layout
            self.revision = revision
            self.manifest = manifest
            context = CordisContext()
            registry = ExtractionBackendRegistry()
        }

        /// Supplies every fixed host dependency this suite's plugins require.
        func supplyAll() async throws {
            try await context.supply(
                ExtractionServiceKeys.backends,
                value: registry)
            try await context.supply(
                ExtractionServiceKeys.extractorCatalogReader,
                value: ExtractorPackageCatalogReader(layout: layout))
            try await context.supply(
                ExtractionServiceKeys.managedProcessExecutor,
                value: ManagedExtractorProcessExecutor())
            try await context.supply(
                ExtractionServiceKeys.packageAdmissionChecker,
                value: AlwaysAdmitted())
            try await context.supply(
                ExtractionServiceKeys.packageStoreLayout,
                value: layout)
            try await context.supply(
                ExtractionServiceKeys.packageSourceLocator,
                value: InstalledExtractorPackageSourceLocator(layout: layout))
        }

        func cleanup() {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Generated plugin fixture cleanup failed: \(error)") }
        }

        private static func findFixtureExecutable() throws -> URL {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let buildRoot = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
            let enumerator = FileManager.default.enumerator(
                at: buildRoot,
                includingPropertiesForKeys: [.isExecutableKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let candidate = enumerator?.nextObject() as? URL {
                if candidate.lastPathComponent == "ManagedExtractorFixture",
                   FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
            throw EnvironmentError.missingFixtureExecutable
        }
    }
}

struct AlwaysAdmitted: ProcessPackageAdmissionChecking {
    func isAdmitted(_ revision: ExtractorPackageRevisionID) async -> Bool { true }
}

final class SupplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    let target: CordisContext
    let expected: Int
    var suppliedCount: Int {
        lock.withLock { storage }
    }

    init(target: CordisContext, expected: Int) {
        self.target = target
        self.expected = expected
    }
}
