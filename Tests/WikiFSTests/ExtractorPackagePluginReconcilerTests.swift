import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSExtractorStore
@testable import WikiFSCore
import WikiFSTypes

@Suite("Extractor package plugin reconciler", .serialized, .timeLimit(.minutes(3)))
struct ExtractorPackagePluginReconcilerTests {
    @Test func appliesFirstGenerationRegistersBothKinds() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        let report = await harness.reconciler.reconcileNow()
        #expect(report.skippedAsUnchanged == false)
        #expect(report.observedGeneration == 1)
        #expect(report.appliedGeneration == 1)
        #expect(report.registeredDefinitionIDs.count == 1)
        #expect(report.failedPackages.isEmpty)

        let matchesPDF = await harness.registry.installedMatches(kind: .pdf)
        let matchesHTML = await harness.registry.installedMatches(kind: .html)
        #expect(matchesPDF.count == 1)
        #expect(matchesHTML.count == 1)

        let observation = await harness.reconciler.observation()
        #expect(observation.appliedGeneration == 1)
        #expect(observation.retainedFailures.isEmpty)
    }

    @Test func unchangedGenerationShortCircuitsWithoutForce() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }
        _ = await harness.reconciler.reconcileNow()

        let second = await harness.reconciler.reconcileNow()
        #expect(second.skippedAsUnchanged)
        #expect(second.appliedGeneration == nil)

        let forced = await harness.reconciler.reconcileNow(force: true)
        #expect(forced.skippedAsUnchanged == false)
        #expect(forced.appliedGeneration == 1)
    }

    @Test func removalPublishesThenDrainsRegistrationsAndUndefines() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }
        _ = await harness.reconciler.reconcileNow()

        // The app-side removal path publishes the emptied generation first;
        // payload cleanup is irrelevant to this layer.
        let writer = try ExtractorPackageCatalogWriter.testing(layout: harness.layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 1, records: [])

        let report = await harness.reconciler.reconcileNow()
        #expect(report.removedCount == 1)
        #expect(report.registeredDefinitionIDs.isEmpty)

        #expect(await harness.registry.installedMatches(kind: .pdf).isEmpty)
        #expect(await harness.registry.installedMatches(kind: .html).isEmpty)

        let observation = await harness.reconciler.observation()
        #expect(observation.appliedGeneration == 2)
        let lifecycles = observation.hostedPlugins.map(\.lifecycle)
        #expect(lifecycles.allSatisfy { $0 == .undefined })
    }

    @Test func corruptCatalogKeepsCurrentGraphUntouched() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }
        _ = await harness.reconciler.reconcileNow()

        try FileManager.default.createDirectory(
            at: harness.layout.derivedRoot,
            withIntermediateDirectories: true)
        guard chmod(harness.layout.derivedIndexURL.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        try Data("not-json".utf8).write(to: harness.layout.derivedIndexURL)

        let report = await harness.reconciler.reconcileNow(force: true)
        #expect(report.observedGeneration == nil)
        #expect(report.appliedGeneration == nil)
        #expect(report.skippedAsUnchanged == false)

        // Known-good process state is preserved even though the durable view
        // is unreadable; preparation-time revalidation remains authoritative.
        #expect(await harness.registry.installedMatches(kind: .pdf).count == 1)

        let observation = await harness.reconciler.observation()
        #expect(observation.retainedFailures.isEmpty == false)
    }

    @Test func invalidInstalledBytesYieldRedactedFailureOnlyForThatPackage() async throws {
        let harness = try await Harness.make()
        defer { harness.cleanup() }

        // Corrupt exact installed bytes beneath the normalized read-only mode.
        let entryURL = harness.layout.packageURL(
            harness.revision.packageID,
            version: harness.revision.version
        ).appendingPathComponent("bin/fixture")
        guard chmod(entryURL.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        try Data("corrupted".utf8).write(to: entryURL)

        let report = await harness.reconciler.reconcileNow()
        #expect(report.registeredDefinitionIDs.isEmpty)
        #expect(report.failedPackages.count == 1)
        #expect(report.failedPackages.first?.packageID == "org.example.generated")
        #expect(report.failedPackages.first?.message.contains("/") == false)
        #expect(await harness.registry.allKeys().isEmpty)

        // Retained for inspection and bounded.
        let observation = await harness.reconciler.observation()
        #expect(observation.retainedFailures.isEmpty == false)
        #expect(observation.retainedFailures.count <= ExtractorPackagePluginReconciler.maximumRetainedFailures)
    }

    private struct Harness {
        let root: URL
        let context: CordisContext
        let registry: ExtractionBackendRegistry
        let layout: ExtractorPackageStoreLayout
        let reader: ExtractorPackageCatalogReader
        let reconciler: ExtractorPackagePluginReconciler
        let revision: ExtractorPackageRevisionID

        static func make() async throws -> Harness {
            let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
            try await environment.supplyAll()

            let layout = environment.layout
            let host = DynamicPluginHost(context: environment.context)
            let reconciler = ExtractorPackagePluginReconciler(
                host: host,
                catalogReader: ExtractorPackageCatalogReader(layout: layout),
                layout: layout)
            return Harness(
                root: environment.root,
                context: environment.context,
                registry: environment.registry,
                layout: layout,
                reader: ExtractorPackageCatalogReader(layout: layout),
                reconciler: reconciler,
                revision: environment.revision)
        }

        func cleanup() {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Reconciler harness cleanup failed: \(error)") }
        }
    }
}
